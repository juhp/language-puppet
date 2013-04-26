{-| This module exports the 'getCatalog' function, that computes catalogs from
parsed manifests. The behaviour of this module is probably non canonical on many
details. The problem is that most of Puppet behaviour is undocumented or
extremely vague. It might be possible to delve into the source code or to write
tests, but ruby is unreadable and tests are boring.

Here is a list of known discrepencies with Puppet :

* Resources references using the \<| |\> syntax are not yet supported.

* Things defined in classes that are not included cannot be accessed. In vanilla
puppet, you can use subclass to classes that are not imported themselves.

* Amending attributes with a reference will not cause an error when done out of
an inherited class.

* Variables $0 to $9, set after regexp matching, are not handled.

* Tags work like regular parameters, and are not automatically populated or inherited.

* Modules, nodes, classes and type names starting with _ are allowed.

* Arrows between resource declarations or collectors are not yet handled.

* Reversed form arrows are not handled.

* Node inheritance is not handled, and class inheritance seems to work well,
but is probably not Puppet-perfect.

-}
module Puppet.Interpreter.Catalog (
    getCatalog
    ) where

import Puppet.DSL.Types
import Puppet.Interpreter.Functions
import Puppet.Interpreter.Types
import Puppet.Printers
import Puppet.Plugins
import qualified PuppetDB.Query as PDB
import Puppet.Utils

import qualified Data.Aeson as JSON
import System.IO.Unsafe
import Control.Arrow (first,(***))
import Data.List
import Data.Char (isAlpha, isAlphaNum)
import Data.Maybe (isJust, fromJust, catMaybes, isNothing, mapMaybe)
import Data.Either (lefts, rights, partitionEithers)
import Data.Ord (comparing)
import Text.Parsec.Pos
import Control.Monad.State
import Control.Monad.Error
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Traversable as DT
import qualified Data.Graph as Graph
import qualified Data.Tree as Tree
import qualified Data.Text as T

qualified :: T.Text -> Bool
qualified = T.isInfixOf "::"

-- Int handling stuff
readint :: T.Text -> CatalogMonad Integer
readint x = case readDecimal x of
                Right y -> return y
                Left _ -> throwPosError $ "Expected an integer instead of '" <> x

-- | This function returns an error, or the 'FinalCatalog' of resources to
-- apply, the map of all edges between resources, and the 'FinalCatalog' of
-- exported resources.
getCatalog :: (TopLevelType -> T.Text -> IO (Either String Statement))
    -- ^ The \"get statements\" function. Given a top level type and its name it
    -- should return the corresponding statement.
    -> (T.Text -> T.Text -> Map.Map T.Text GeneralValue -> IO (Either String T.Text))
    -- ^ The \"get template\" function. Given a file name, a scope name and a
    -- list of variables, it should return the computed template.
    -> (T.Text -> PDB.Query -> IO (Either String JSON.Value))
    -- ^ The \"puppetDB Rest API\" function. Given the machine fqdn, a request
    -- type (resources, nodes, facts, ..) and a query, it returns a
    -- JSON value, or some error.
    -> T.Text -- ^ Name of the node.
    -> Facts -- ^ Facts of this node.
    -> Maybe T.Text -- ^ Path to the modules, for user plugins. If set to Nothing, plugins are disabled.
    -> Map.Map PuppetTypeName PuppetTypeMethods -- ^ The list of native types
    -> IO (Either String (FinalCatalog, EdgeMap, FinalCatalog), [T.Text])
getCatalog getstatements gettemplate puppetdb nodename facts modules ntypes = do
    let convertedfacts = Map.map
            (\fval -> (Right fval, initialPos "FACTS"))
            facts
    (luastate, userfunctions) <- case modules of
        Just m  -> fmap (first Just) (initLua m)
        Nothing -> return (Nothing, [])
    (!output, !finalstate) <- runStateT ( runErrorT ( computeCatalog getstatements nodename ) )
                                ScopeState
                                   { curScope                   = [["::"]]
                                   , curVariables               = convertedfacts
                                   , curClasses                 = Map.empty
                                   , curDefaults                = Map.empty
                                   , curResId                   = 1
                                   , curPos                     = (initialPos "dummy")
                                   , nestedtoplevels            = Map.empty
                                   , getStatementsFunction      = getstatements
                                   , getWarnings                = []
                                   , curCollect                 = []
                                   , unresolvedRels             = []
                                   , computeTemplateFunction    = gettemplate
                                   , puppetDBFunction           = puppetdb
                                   , luaState                   = luastate
                                   , userFunctions              = Set.fromList userfunctions
                                   , nativeTypes                = ntypes
                                   , definedResources           = Map.singleton ("node",nodename) (newPos "site.pp" 0 0)
                                   , currentDependencyStack     = [("node",nodename)]
                                   }
    case luastate of
        Just l  -> closeLua l
        Nothing -> return ()
    case output of
        Left x -> return (Left (T.unpack x), getWarnings finalstate)
        Right x -> return (Right x, getWarnings finalstate)

computeCatalog :: (TopLevelType -> T.Text -> IO (Either String Statement)) -> T.Text -> CatalogMonad (FinalCatalog, EdgeMap, FinalCatalog)
computeCatalog getstatements nodename = do
    nodestatements <- liftIO $ getstatements TopNode nodename
    case nodestatements of
        Left x -> throwError (T.pack x)
        Right nodestmts -> evaluateStatements nodestmts >>= finalResolution

resolveResource :: CResource -> CatalogMonad (ResIdentifier, RResource)
resolveResource cr@(CResource cid cname ctype cparams _ scopes cpos) = do
    setPos cpos
    rname <- resolveGeneralString cname
    rparams <- mapM (\(a,b) -> do { ra <- resolveGeneralString a; rb <- resolveGeneralValue b; return (ra,rb); }) (Map.toList cparams)
    nparams <- processOverride cr (Map.fromList rparams)
    let mrrelations = []
        prefinalresource = RResource cid rname ctype nparams mrrelations scopes cpos
    return ((ctype, rname), prefinalresource)

-- this validates the resolved resources
-- it should only be called with native types or the validatefunction lookup with abord with an error
finalizeResource :: CResource -> CatalogMonad (ResIdentifier, RResource)
finalizeResource cr = do
    ((_, rname), prefinalresource) <- extractRelations cr >>= resolveResource
    let ctype   = rrtype   prefinalresource
        cpos    = rrpos    prefinalresource
        saveAlias :: ResolvedValue -> CatalogMonad ()
        saveAlias (ResolvedString al) | al == rname = return ()
                                      | otherwise = addDefinedResource (ctype, al) cpos
        saveAlias x = throwPosError ("This alias is not a string:" <> tshow x)
    setPos cpos
    ntypes <- fmap nativeTypes get
    unless (Map.member ctype ntypes) $ throwPosError $ "Can't find native type " <> ctype
    -- now run the collection checks for overrides
    let validatefunction = puppetvalidate (ntypes Map.! ctype)
        validated = validatefunction prefinalresource
    case validated of
        Left err -> throwPosError (T.pack err <> " for resource " <> ctype <> "[" <> rname <> "]")
        Right finalresource -> do
            case Map.findWithDefault (ResolvedArray []) "alias" (rrparams finalresource) of
                (ResolvedArray aliases) -> mapM_ saveAlias aliases
                s@(ResolvedString _)    -> saveAlias s
                x                       -> throwPosError ("Aliases should be arrays of strings, not " <> tshow x)
            return ((ctype, rname), finalresource)

-- This checks if a resource is to be collected.
-- This returns a list as it can either return the original
-- resource, the resource with a "normal" virtuality, or both,
-- for exported resources (so that they can still be found as collected)
collectionChecks :: CResource -> CatalogMonad [CResource]
collectionChecks res =
    if crvirtuality res == Normal
        then return [res]
        else do
            -- Note that amending attributes with a collector does collect virtual
            -- values. Hence no filtering on the collectors is done here.
            isCollected <- liftM curCollect get >>= mapM (\(x, _, _) -> x res)
            case (or isCollected, crvirtuality res) of
                (True, Exported)    -> return [res { crvirtuality = Normal }, res]
                (True,  _)          -> return [res { crvirtuality = Normal }     ]
                (False, _)          -> return [res                               ]

processOverride :: CResource -> Map.Map T.Text ResolvedValue -> CatalogMonad (Map.Map T.Text ResolvedValue)
processOverride cr prms =
    let applyOverride :: CResource -> Map.Map T.Text ResolvedValue -> (CResource -> CatalogMonad Bool, Map.Map GeneralString GeneralValue, Maybe PDB.Query) -> CatalogMonad (Map.Map T.Text ResolvedValue)
        -- this checks if the collection function matches
        applyOverride c prm (func, overs, _) = do
            check <- func c
            if check
                then foldM tryReplace prm (Map.toList overs)
                else return prm
        tryReplace :: Map.Map T.Text ResolvedValue -> (GeneralString, GeneralValue) -> CatalogMonad (Map.Map T.Text ResolvedValue)
        -- if it does, this resolves the override and applies it
        -- this is obviously wasteful
        tryReplace curmap (gs, gv) = do
            rs <- resolveGeneralString gs
            rv <- resolveGeneralValue gv
            return $ Map.insert rs rv curmap
    -- Collectors are filtered so that only those with overrides are passed to the fold.
    in liftM (filter (\(_, x, _) -> not $ Map.null x) . curCollect) get >>= foldM (applyOverride cr) prms

retrieveRemoteResources :: (PDB.Query -> IO (Either String [CResource])) -> PDB.Query -> CatalogMonad [CResource]
retrieveRemoteResources f q = do
    res <- liftIO $ f q
    case res of
        Right h     -> return h
        Left err    -> throwError $ "PuppetDB error: " <> T.pack err

extractRelations :: CResource -> CatalogMonad CResource
extractRelations cr = do
    setPos (pos cr)
    (params, relations) <- partitionParamsRelations (crparams cr)
    addUnresRel (relations, (crtype cr, crname cr), UNormal, pos cr, crscope cr)
    return cr { crparams = params }

-- resolves a single relationship
resolveRelationship :: ([(LinkType, GeneralValue, GeneralValue)], (T.Text, GeneralString), RelUpdateType, SourcePos, [[ScopeName]])
                        -> CatalogMonad ([(LinkType, ResIdentifier)], ResIdentifier, RelUpdateType, SourcePos, [[ScopeName]])
resolveRelationship (udsts, (stype, usname), uptype, spos, scop) = do
    let resolveSrcRel (ltype, udtype, udname) = do
            dtype <- resolveGeneralValue udtype >>= rstring
            resolveGeneralValue udname >>= rstrings >>= mapM (\dname -> return (ltype, (dtype, dname)))
    dsts  <- fmap concat (mapM resolveSrcRel udsts)
    sname <- resolveGeneralString usname
    return (dsts, (stype, sname), uptype, spos, scop)

-- this does all the relation stuff
finalizeRelations :: FinalCatalog -> FinalCatalog -> CatalogMonad (FinalCatalog, EdgeMap)
finalizeRelations exported cat = do
    grels <- fmap unresolvedRels get >>= mapM resolveRelationship
    drs   <- fmap definedResources get
    let extr :: ([(LinkType, ResIdentifier)], ResIdentifier, RelUpdateType, SourcePos, [[ScopeName]])
                    -> [(ResIdentifier, ResIdentifier, LinkInfo)]
        extr (dsts, src, rutype, spos, scp) = do
            (ltype, dst) <- dsts
            return (dst, src, (ltype, rutype, spos, scp))
        !rels = concatMap extr grels :: [(ResIdentifier, ResIdentifier, LinkInfo)]
        checkRelationExists :: (ResIdentifier, ResIdentifier, LinkInfo) -> CatalogMonad (Maybe (ResIdentifier, ResIdentifier, LinkInfo))
        checkRelationExists !o@(!src, !dst, (!ltype,!lutype,!lpos,!lscope)) =
            -- if the source of the relation doesn't exist (is exported),
            -- then when drop this relation
            case (Map.member src drs, Map.member dst drs, Map.member src exported, Map.member dst exported) of
                (_, _, _, True)     -> return Nothing
                -- we have a good relation, reorder it so that all arrows point the same way
                (True, True,_ , _)  -> case ltype of
                                RNotify -> return $ Just (dst, src, (RSubscribe, lutype,lpos,lscope))
                                RBefore -> return $ Just (dst, src, (RRequire  , lutype,lpos,lscope))
                                _ -> return (Just o)
                (False, _, _, _)  -> throwError $ "Unknown resources " <> tshow src <> " used as source (destination: " <> tshow dst <> ") in a relation at " <> tshow lpos <> " debug: " <> tshow (Map.member src drs, Map.member dst drs, Map.member src exported, Map.member dst exported) <> " " <> showScope lscope
                (_, False, _, _)  -> throwError $ "Unknown resources " <> tshow dst <> " used as destination (source: " <> tshow src <> ") in a relation at " <> tshow lpos <> " debug: " <> tshow (Map.member src drs, Map.member dst drs, Map.member src exported, Map.member dst exported) <> " " <> showScope lscope
    -- now look for cycles in the graph
    checkedrels <- fmap catMaybes $ mapM checkRelationExists rels
    let !edgeMap = Map.fromList (map (\(d,s,i) -> ((s,d),i)) checkedrels) :: EdgeMap -- warning, in the edgemap we have (src, dst), contrary to all other uses
        !nodeRel = Map.fromListWith (++) (map (\(d,s,_) -> (s,[d])) checkedrels) :: Map.Map ResIdentifier [ResIdentifier]
        !(relgraph,qfunc) = Graph.graphFromEdges' $ map (\(a,b) -> (a,a,b)) $ Map.toList nodeRel
        !cycles = map (map ((\(a,_,_) -> a) . qfunc) . Tree.flatten) $ filter (not . null . Tree.subForest) $ Graph.scc relgraph :: [[ResIdentifier]]
        describe :: [ResIdentifier] -> T.Text
        describe [] = "[]"
        describe x = let rx = map (\i -> (i, drs Map.! i)) x
                     in  T.intercalate "\n\t\t" (showRRef (head x) : zipWith describe' x (tail rx))
        describe' :: ResIdentifier -> (ResIdentifier, SourcePos) -> T.Text
        describe' src (dst,dpos) = " -> " <> showRRef dst <> " [" <> tshow dpos <> "] link is " <> tshow (Map.lookup (src,dst) edgeMap)
    if null cycles
        then return (cat, edgeMap)
        else throwError $ "The following cycles have been found:\n\t" <> T.intercalate "\n\t" (map describe cycles)


finalResolution :: Catalog -> CatalogMonad (FinalCatalog, EdgeMap, FinalCatalog)
finalResolution cat = do
    pdbfunction     <- fmap puppetDBFunction get
    fqdnr           <- getVariable "::fqdn"
    collectedRemote <- do
                           fqdn <- case fqdnr of
                               Just (Right (ResolvedString f'), _) -> return f'
                               _ -> throwError "Could not get FQDN during final resolution"
                           remoteCollects <- fmap (mapMaybe (\(_,_,x) -> x) . curCollect) get
                           let
                               isNotLocal :: CResource -> Bool
                               isNotLocal cr = case Map.lookup (Right "EXPORTEDSOURCE") (crparams cr) of
                                                        Just (Right (ResolvedString x)) -> x /= fqdn
                                                        _ -> True
                               toCR :: Either String JSON.Value -> Either String [CResource]
                               toCR (Left r) = Left r
                               toCR (Right x) = case json2puppet x of
                                                    Left rr -> Left rr
                                                    Right s -> Right $ filter isNotLocal s
                           fmap concat (mapM (retrieveRemoteResources (fmap toCR . pdbfunction "resources")) remoteCollects)
    let -- this adds the collected remote defines to the index of know resources, so that the dependencies check
        addCollectedDefines cr = do
            let rtype  = crtype cr
            rname <- resolveGeneralString (crname cr)
            isdef <- checkDefine rtype
            case isdef of
               Just _  -> addDefinedResource (rtype, rname) (pos cr)
               Nothing -> return ()
    collectedRemote' <- mapM extractRelations collectedRemote
    mapM_ addCollectedDefines collectedRemote'
    collectedLocal   <- fmap concat $ mapM collectionChecks cat
    collectedLocalD  <- fmap concat $ mapM evaluateDefine collectedLocal
    collectedRemoteD <- fmap concat $ mapM evaluateDefine collectedRemote'
    -- collectedRemoteD resource names SHOULD be resolved (coming from
    -- PuppetDB)
    let addCollectedRemoteResource :: CResource -> CatalogMonad ()
        addCollectedRemoteResource (CResource _ (Right cn) ct prms _ _ cp) = do
            addDefinedResource (ct, cn) cp
            case Map.lookup (Right "alias") prms of
                Just (Right (ResolvedString s)) -> addDefinedResource (ct, s) cp
                Just x -> throwPosError ("Alias must be a single string, not " <> tshow x)
                _ -> return ()
        addCollectedRemoteResource x = throwPosError $ "finalResolution/addCollectedRemoteResource the remote resource name was not properly defined: " <> tshow (crname x)
    mapM_ addCollectedRemoteResource collectedRemoteD
    let collected = collectedLocalD ++ collectedRemoteD
        (real,  allvirtual)  = partition (\x -> crvirtuality x == Normal) collected
        (_,  exported) = partition (\x -> crvirtuality x == Virtual)  allvirtual
    rexported <- mapM resolveResource exported
    let !exportMap = Map.fromList rexported
    -- TODO
    --export stuff
    --liftIO $ putStrLn "EXPORTED:"
    --liftIO $ mapM print exported
    --get >>= return . unresolvedRels >>= liftIO . (mapM print)
    (fc, em) <- mapM finalizeResource real >>= createResourceMap >>= finalizeRelations exportMap
    return (fc, em, exportMap)

createResourceMap :: [(ResIdentifier, RResource)] -> CatalogMonad FinalCatalog
createResourceMap = foldM insertres Map.empty
    where
        insertres :: FinalCatalog -> (ResIdentifier, RResource) -> CatalogMonad FinalCatalog
        insertres curmap (resid, res) = let
            oldres = Map.lookup resid curmap
            newmap = Map.insert resid res curmap
            in case (rrtype res, oldres) of
                ("class", _) -> return newmap
                (_, Just r ) -> throwError ("Resource already defined:"
                    <> "\n\t" <> rrtype r   <> "[" <> rrname r   <> "] at " <> tshow (rrpos r)   <> " " <> showScope (rrscope r)
                    <> "\n\t" <> rrtype res <> "[" <> rrname res <> "] at " <> tshow (rrpos res) <> " " <> showScope (rrscope res) :: T.Text)
                (_, Nothing) -> return newmap

getstatement :: TopLevelType -> T.Text -> CatalogMonad Statement
getstatement qtype name = do
    curcontext <- get
    let stmtsfunc = getStatementsFunction curcontext
    estatement <- liftIO $ stmtsfunc qtype name
    case estatement of
        Left x -> throwPosError (T.pack x)
        Right y -> return y

-- State alteration functions

pushDefaults :: ResDefaults -> CatalogMonad ()
pushDefaults d = do
    curstate <- get
    let curscope = (head . curScope) curstate
        curdefaults = curDefaults curstate
        newdefaults = Map.insertWith (++) curscope [d] curdefaults
    put (curstate { curDefaults = newdefaults })

emptyDefaults :: CatalogMonad ()
emptyDefaults = do
    curstate <- get
    let curscope = (head . curScope) curstate
        curdefaults = curDefaults curstate
        newdefaults = Map.delete curscope curdefaults
    put (curstate { curDefaults = newdefaults })

getCurDefaults :: CatalogMonad [ResDefaults]
getCurDefaults = do
    curstate <- get
    let curscope = (head . curScope) curstate
        curdefaults = curDefaults curstate
    case Map.lookup curscope curdefaults of
        Nothing -> return []
        Just  x -> return x

pushDependency :: ResIdentifier -> CatalogMonad ()
pushDependency = modify . modifyDeps . (:)
popDependency :: CatalogMonad ()
popDependency = modify (modifyDeps tail)
pushScope :: [ScopeName] -> CatalogMonad ()
pushScope = modify . modifyScope . (:)
popScope :: CatalogMonad ()
popScope       = modify (modifyScope tail)
getScope :: CatalogMonad [T.Text]
getScope        = do
    scope <- liftM curScope get
    if null scope
        then throwError "empty scope, shouldn't happen"
        else return $ head scope
addLoaded :: T.Text -> SourcePos -> CatalogMonad ()
addLoaded name = modify . modifyClasses . Map.insert name
getNextId = do
    curscope <- get
    put $ incrementResId curscope
    return (curResId curscope)
setPos = modify . setStatePos

-- qualifies a variable k depending on the context cs
qualify k cs | qualified k || (cs == "::") = cs <> k
             | otherwise = cs <> "::" <> k

-- This is a bit convoluted and misses a critical feature.
-- It adds the variable to all the scopes that are currently active.
-- BUG TODO : check that a variable is not already defined.
putVariable k v = getScope >>= mapM_ (\x -> modify (modifyVariables (Map.insert (qualify k x) v)))

-- Saves the current module name
setModuleName :: T.Text -> CatalogMonad ()
setModuleName str = do
    let (amodulename, remain) = T.break (==':') str
        modulename = if T.null remain
                         then "topmodule"
                         else amodulename
    cpos <- getPos
    vars <- fmap curVariables get
    let nvars = Map.insert "::caller_module_name" (Right (ResolvedString modulename), cpos) vars
    saveVariables nvars

getVariable vname = liftM (Map.lookup vname . curVariables) get

-- BUG TODO : top levels are qualified only with the head of the scopes
addNestedTopLevel rtype rname rstatement = do
    curstate <- get
    let ctop = nestedtoplevels curstate
        curscope = head $ head (curScope curstate)
        nname = qualify rname curscope
        nstatement = case rstatement of
            DefineDeclaration _ prms stms cpos      -> DefineDeclaration nname prms stms cpos
            ClassDeclaration  _ inhe prms stms cpos -> ClassDeclaration  nname inhe prms stms cpos
            x -> x
        ntop = Map.insert (rtype, nname) nstatement ctop
        nstate = curstate { nestedtoplevels = ntop }
    put nstate
addWarning :: T.Text -> CatalogMonad ()
addWarning = modify . pushWarning
addCollect ((func, query), overrides) = modify $ pushCollect (func, overrides, query)
-- this pushes the relations only if they exist
-- the parameter is of the form
-- ( [dstrelations], srcresource, type, pos )
addUnresRel :: ([(LinkType, GeneralValue, GeneralValue)], (T.Text, GeneralString), RelUpdateType, SourcePos, [[ScopeName]]) -> CatalogMonad ()
addUnresRel ncol@(rels, _, _, _, _)  = unless (null rels) (modify (pushUnresRel ncol))

-- finds out if a resource name refers to a define
checkDefine :: T.Text -> CatalogMonad (Maybe Statement)
checkDefine dname = fmap nativeTypes get >>= \nt -> if Map.member dname nt
  then return Nothing
  else do
    curstate <- get
    let ntop = nestedtoplevels curstate
        getsmts = getStatementsFunction curstate
        check = Map.lookup (TopDefine, dname) ntop
    case check of
        Just x -> return $ Just x
        Nothing -> do
            def1 <- liftIO $ getsmts TopDefine dname
            case def1 of
                Left err -> throwPosError ("Could not find the definition of " <> dname <> " err = " <> T.pack err)
                Right s -> return $ Just s

{-
Partition parameters between those that are actual parameters and those that define relationships.

Those that define relationship must be properly resolved or hell will break loose. This is a BUG.
-}
partitionParamsRelations :: Map.Map GeneralString GeneralValue -> CatalogMonad (Map.Map GeneralString GeneralValue, [(LinkType, GeneralValue, GeneralValue)])
partitionParamsRelations rparameters = do
    let realparams = filteredparams :: Map.Map GeneralString GeneralValue
        convertrelation :: (GeneralString, GeneralValue) -> CatalogMonad [(LinkType, GeneralValue, GeneralValue)]
        convertrelation (_,       Right ResolvedUndefined)          = return []
        convertrelation (reltype, Right (ResolvedArray rs))         = fmap concat $ mapM (\x -> convertrelation (reltype, Right x)) rs
        convertrelation (reltype, Right (ResolvedRReference rt rv)) = return [(fromJust $ getRelationParameterType reltype, Right $ ResolvedString rt, Right rv)]
        convertrelation (reltype, Right (ResolvedString "undef"))   = return [(fromJust $ getRelationParameterType reltype, Right $ ResolvedString "undef", Right $ ResolvedString "undef")]
        convertrelation (reltype, Right (ResolvedString x))         = case parseResourceReference x of
                                                                          Just rr -> convertrelation (reltype, Right rr)
                                                                          Nothing -> throwPosError ("partitionParamsRelations unknown string error : " <> tshow x)
        convertrelation (_,       Left x)                           = throwPosError ("partitionParamsRelations unresolved : " <> tshow x)
        convertrelation x                                           = throwPosError ("partitionParamsRelations error : " <> tshow x)
        (filteredrelations, filteredparams)                         = Map.partitionWithKey (const . isJust . getRelationParameterType) rparameters -- filters relations with actual parameters
    relations <- fmap concat (mapM convertrelation (Map.toList filteredrelations)) :: CatalogMonad [(LinkType, GeneralValue, GeneralValue)]
    return (realparams, relations)

-- TODO check whether parameters changed
checkLoaded :: T.Text -> CatalogMonad Bool
checkLoaded name = do
    curscope <- get
    case Map.lookup name (curClasses curscope) of
        Nothing -> return False
        Just _  -> return True

-- function that takes a pair of Expressions and try to resolve the first as a string, the second as a generalvalue
resolveParams :: (Expression, Expression) -> CatalogMonad (GeneralString, GeneralValue)
resolveParams (a,b) = do
    ra <- tryResolveExpressionString a
    rb <- tryResolveExpression b
    return (ra, rb)

-- safely insert parameters, checking they are not already defined
addParameters :: Map.Map GeneralString GeneralValue -> [(Expression, Expression)] -> CatalogMonad (Map.Map GeneralString GeneralValue)
addParameters = foldM rp
    where
        rp :: Map.Map GeneralString GeneralValue -> (Expression, Expression) -> CatalogMonad (Map.Map GeneralString GeneralValue)
        rp curmap prm = do
            (k, v) <- resolveParams prm
            case Map.lookup k curmap of
                Just _ -> throwPosError $ "Parameter " <> tshow k <> " had been declared twice!"
                Nothing -> return (Map.insert k v curmap)

-- apply default values to a resource
applyDefaults :: CResource -> CatalogMonad CResource
applyDefaults res = getCurDefaults >>= foldM applyDefaults' res

applyDefaults' :: CResource -> ResDefaults -> CatalogMonad CResource
applyDefaults' r@(CResource i rname rtype rparams rvirtuality scopes rpos) (RDefaults dtype rdefs _) =
    let nparams = mergeParams rparams rdefs False
    in  return $ if dtype == rtype
                     then CResource i rname rtype nparams rvirtuality scopes rpos
                     else r
applyDefaults' r@(CResource i rname rtype rparams rvirtuality scopes rpos) (ROverride dtype dname rdefs _) = do
    srname <- resolveGeneralString rname
    sdname <- resolveGeneralString dname
    let nparams = mergeParams rparams rdefs True
    return $ if (dtype == rtype) && (srname == sdname)
                 then CResource i rname rtype nparams rvirtuality scopes rpos
                 else r

-- merge defaults and actual parameters depending on the override flag
mergeParams :: Map.Map GeneralString GeneralValue -> Map.Map GeneralString GeneralValue -> Bool -> Map.Map GeneralString GeneralValue
mergeParams srcprm defs override = if override
                                       then defs   `Map.union` srcprm
                                       else srcprm `Map.union` defs

-- The actual meat

evaluateDefine :: CResource -> CatalogMonad [CResource]
evaluateDefine r@(CResource _ rname rtype rparams rvirtuality _ rpos) = let
    evaluateDefineDeclaration dtype args dstmts dpos = do
        rexpr <- resolveGeneralString rname
        pushScope ["#DEFINE#" <> dtype <> "/" <> rexpr]
        pushDependency (dtype, rexpr)
        -- add variables
        mparams <- fmap Map.fromList $ mapM (\(gs, gv) -> do { rgs <- resolveGeneralString gs; rgv <- tryResolveGeneralValue gv; return (rgs, (rgv, dpos)); }) (Map.toList rparams)
        let expr = Right (ResolvedString rexpr)
            defineparamset = Set.fromList $ map fst args
            mandatoryparams = Set.fromList $ map fst $ filter (isNothing . snd) args
            resourceparamset = Map.keysSet mparams
            extraparams = Set.difference resourceparamset (defineparamset `Set.union` metaparameters)
            unsetparams = Set.difference mandatoryparams resourceparamset
        unless (Set.null extraparams) $ throwPosError $ "Spurious parameters set for " <> dtype <> ": " <> T.intercalate ", " (Set.toList extraparams)
        unless (Set.null unsetparams) $ throwPosError $ "Unset parameters set for "    <> dtype <> ": " <> T.intercalate ", " (Set.toList unsetparams)
        putVariable "title" (expr, rpos)
        putVariable "name" (expr, rpos)
        mapM_ (loadClassVariable rpos mparams) args

        setPos dpos
        setModuleName dtype
        -- parse statements
        res <- mapM evaluateStatements dstmts
        nres <- handleDelayedActions (concat res)
        popDependency
        popScope
        return nres
    in do
    setPos rpos
    isdef <- checkDefine rtype
    case (rvirtuality, isdef) of
        (Normal, Just (TopContainer topstmts (DefineDeclaration dtype args dstmts dpos))) -> do
            mapM_ (\(n,x) -> evaluateClass x Map.empty (Just n)) topstmts
            evaluateDefineDeclaration dtype args dstmts dpos
        (Normal, Just (DefineDeclaration dtype args dstmts dpos)) -> evaluateDefineDeclaration dtype args dstmts dpos
        _ -> return [r]


-- handling delayed actions (such as defaults and define resolution)
handleDelayedActions :: Catalog -> CatalogMonad Catalog
handleDelayedActions res = do
    dres <- liftM concat (mapM applyDefaults res >>= mapM evaluateDefine)
    emptyDefaults
    return dres

addResource :: T.Text -> [(Expression, Expression)] -> Virtuality -> SourcePos -> GeneralValue -> CatalogMonad [CResource]
addResource rtype parameters virtuality position grname = do
    resid <- getNextId
    rparameters <- addParameters Map.empty parameters
    case grname of
        Right e -> do
            rse <- rstring e
            curpos <- getPos
            addDefinedResource (rtype, rse) curpos
            case Map.lookup (Right "alias") rparameters of
                Just (Right (ResolvedString s)) -> addDefinedResource (rtype, s) curpos
                Just x -> throwPosError ("Alias must be a single string, not " <> tshow x)
                _ -> return ()
            (curdeptype, curdepname) <- fmap (head . currentDependencyStack) get
            let defaultdependency = (RRequire, Right (ResolvedString curdeptype), Right (ResolvedString curdepname))
            scopes <- fmap curScope get
            addUnresRel ([defaultdependency], (rtype, Right rse), UNormal, position, scopes)
            return [CResource resid (Right rse) rtype rparameters virtuality scopes position]
        Left r -> throwPosError ("Could not determine the current resource name: " <> tshow r)

-- node
evaluateStatements :: Statement -> CatalogMonad Catalog
evaluateStatements (Node _ stmts position) = do
    setPos position
    res <- mapM evaluateStatements stmts
    handleDelayedActions (concat res)

-- include
evaluateStatements (Include includename position) = setPos position >> resolveExpressionString includename >>= getstatement TopClass >>= \st -> evaluateClass st Map.empty Nothing
evaluateStatements x@(ClassDeclaration cname _ _ _ _) = do
    addNestedTopLevel TopClass cname x
    return []
evaluateStatements n@(DefineDeclaration dtype _ _ _) = do
    addNestedTopLevel TopDefine dtype n
    return []
evaluateStatements (ConditionalStatement exprs position) = do
    setPos position
    trues <- filterM (\(expr, _) -> resolveBoolean (Left expr)) exprs
    case trues of
        ((_,stmts):_) -> liftM concat (mapM evaluateStatements stmts)
        _ -> return []

evaluateStatements (Resource rtype rname parameters virtuality position) = do
    setPos position
    case rtype of
        -- checks whether we are handling a parametrized class
        "class" -> do
            rparameters <- fmap Map.fromList $ mapM (\(a,b) -> do { pa <- resolveExpressionString a; pb <- tryResolveExpression b; return (pa, pb) } ) parameters
            classname <- resolveExpressionString rname
            topstatement <- getstatement TopClass classname
            let classparameters = Map.map (\pvalue -> (pvalue, position)) rparameters :: Map.Map T.Text (GeneralValue, SourcePos)
            evaluateClass topstatement classparameters Nothing
        _ -> do
            srname <- tryResolveExpression rname
            case srname of
                (Right (ResolvedArray arr)) -> fmap concat (mapM (addResource rtype parameters virtuality position . Right) arr)
                _ -> addResource rtype parameters virtuality position srname

evaluateStatements (ResourceDefault rdtype rdparams rdpos) = do
    rrdparams <- addParameters Map.empty rdparams
    pushDefaults $ RDefaults rdtype rrdparams rdpos
    return []
evaluateStatements (ResourceOverride rotype roname roparams ropos) = do
    rroname <- tryResolveExpressionString roname
    rroparams <- addParameters Map.empty roparams
    pushDefaults $ ROverride rotype rroname rroparams ropos
    return []
evaluateStatements (DependenceChain (srctype, srcname) (dsttype, dstname) position) = do
    setPos position
    gdstname <- tryResolveExpression dstname
    gsrcname <- tryResolveExpressionString srcname
    scp <- fmap curScope get
    addUnresRel ( [(RRequire, Right $ ResolvedString dsttype, gdstname)], (srctype, gsrcname), UPlus, position, scp)
    return []
-- <<| |>>
evaluateStatements (ResourceCollection rtype expr overrides position) = do
    setPos position
    unless (null overrides) $ throwPosError "Amending attributes with a Collector only works with <| |>, not <<| |>>."
    func <- collectionFunction Exported rtype expr
    addCollect (func, Map.empty)
    return []
-- <| |>
-- TODO : check that this is a native type when overrides are defined.
-- The behaviour is not explained in the documentation, so I won't support it.
evaluateStatements (VirtualResourceCollection rtype expr overrides position) = do
    setPos position
    func <- collectionFunction Virtual rtype expr
    prms <- addParameters Map.empty overrides
    addCollect (func, prms)
    return []

evaluateStatements (VariableAssignment vname vexpr position) = do
    setPos position
    rvexpr <- tryResolveExpression vexpr
    putVariable vname (rvexpr, position)
    return []

evaluateStatements (MainFunctionCall fname fargs position) = do
    setPos position
    rargs <- mapM resolveExpression fargs
    executeFunction fname rargs

evaluateStatements (TopContainer toplevels curstatement) = do
    mapM_ (\(fname, stmt) -> evaluateClass stmt Map.empty (Just fname)) toplevels
    evaluateStatements curstatement

evaluateStatements x = throwError ("Can't evaluate " <> tshow x)

-- function used to load defines / class variables into the global context
loadClassVariable :: SourcePos -> Map.Map T.Text (GeneralValue, SourcePos) -> (T.Text, Maybe Expression) -> CatalogMonad (T.Text, GeneralValue)
loadClassVariable position inputs (paramname, defvalue) = do
    let inputvalue = Map.lookup paramname inputs
    (v, vpos) <- case (inputvalue, defvalue) of
        (Just x , _      ) -> return x
        (Nothing, Just y ) -> return (Left y, position)
        (Nothing, Nothing) -> throwError $ "Must define parameter " <> paramname <> " at " <> tshow position
    rv <- tryResolveGeneralValue v
    putVariable paramname (rv, vpos)
    return (paramname, rv)

-- class
-- ClassDeclaration String (Maybe String) [(String, Maybe Expression)] [Statement] SourcePos
-- nom, heritage, parametres, contenu
evaluateClass :: Statement -> Map.Map T.Text (GeneralValue, SourcePos) -> Maybe T.Text -> CatalogMonad Catalog
evaluateClass (ClassDeclaration classname inherits parameters statements position) inputparams actualname = do
    isloaded <- case actualname of
        Nothing -> checkLoaded classname
        Just x  -> checkLoaded x
    if isloaded
        then return []
        else do
        oldpos <- getPos    -- saves where we were at class declaration so that we known were the class was included
        addDefinedResource ("class", classname) oldpos
        -- detection of spurious parameters
        let classparamset = Set.fromList $ map fst parameters
            inputparamset = Set.filter (isNothing . getRelationParameterType . Right) $ Map.keysSet inputparams
            overparams = Set.difference inputparamset (Set.union metaparameters classparamset)
            -- to insert into the final resource

        unless (Set.null overparams) (throwError $ "Spurious parameters " <> T.intercalate ", " (Set.toList overparams) <> " at " <> tshow position)

        resid <- getNextId  -- get this resource id, for the dummy class that will be used to handle relations
        case actualname of
            Nothing -> pushScope [classname] -- sets the scope
            Just ac -> pushScope [classname, ac]
        mparameters <- mapM (loadClassVariable position inputparams) parameters -- add variables for parametrized classes
        setPos position -- the setPos is that late so that the error message about missing parameters is about the calling site
        pushDependency ("class", classname)
        setModuleName classname

        -- load inherited classes
        inherited <- case inherits of
            Just parentclass -> do
                mystatement <- getstatement TopClass parentclass
                case mystatement of
                    ClassDeclaration _ ni np ns no -> evaluateClass (ClassDeclaration classname ni np ns no) Map.empty (Just parentclass)
                    _ -> throwError "Should not happen : TopClass return something else than a ClassDeclaration in evaluateClass"
            Nothing -> return []
        case actualname of
            Nothing -> addLoaded classname oldpos
            Just x  -> addLoaded x oldpos

        -- parse statements
        res <- mapM evaluateStatements statements
        nres <- handleDelayedActions (concat res)
        mapM_ (addClassDependency classname) nres   -- this adds a dummy dependency to this class
                                                    -- for all resources that do not already depend on a class
                                                    -- this is probably not puppet perfect with resources that
                                                    -- depend explicitely on a class
        scopes <- fmap curScope get
        popScope
        popDependency
        return $
            [CResource resid (Right classname) "class" (Map.fromList $ map (first Right) mparameters) Normal scopes position]
            ++ inherited
            ++ nres

evaluateClass (TopContainer topstmts myclass) inputparams actualname = do
    mapM_ (\(n,x) -> evaluateClass x Map.empty (Just n)) topstmts
    evaluateClass myclass inputparams actualname

evaluateClass x _ _ = throwError ("Someone managed to run evaluateClass against " <> tshow x)

addClassDependency :: T.Text -> CResource -> CatalogMonad ()
addClassDependency cname (CResource _ rname rtype _ _ scp position) =
    addUnresRel (
        [(RRequire, Right $ ResolvedString "class", Right $ ResolvedString cname)]
        , (rtype, rname)
        , UPlus
        , position
        , scp
        )

tryResolveExpression :: Expression -> CatalogMonad GeneralValue
tryResolveExpression = tryResolveGeneralValue . Left

tryResolveGeneralValue :: GeneralValue -> CatalogMonad GeneralValue
tryResolveGeneralValue n@(Right _) = return n
tryResolveGeneralValue   (Left BTrue) = return $ Right $ ResolvedBool True
tryResolveGeneralValue   (Left BFalse) = return $ Right $ ResolvedBool False
tryResolveGeneralValue   (Left (Value x)) = tryResolveValue x
tryResolveGeneralValue n@(Left (ResolvedResourceReference _ _)) = return n
tryResolveGeneralValue   (Left (ConditionalValue checkedvalue (Value (PuppetHash (Parameters hash))))) = do
    rcheck <- resolveExpression checkedvalue
    rhash <- mapM (\(vn, vv) -> do { rvn <- resolveExpression vn; return (rvn, vv) }) hash
    case filter (\(a,_) -> (a == ResolvedString "default") || compareRValues a rcheck) rhash of
        [] -> throwPosError ("No value could be selected when comparing to " <> tshow rcheck)
        ((_,x):_) -> tryResolveExpression x
tryResolveGeneralValue n@(Left (EqualOperation      a b))   = compareGeneralValue n a b [EQ]
tryResolveGeneralValue n@(Left (AboveEqualOperation a b))   = compareGeneralValue n a b [GT,EQ]
tryResolveGeneralValue n@(Left (AboveOperation      a b))   = compareGeneralValue n a b [GT]
tryResolveGeneralValue n@(Left (UnderEqualOperation a b))   = compareGeneralValue n a b [LT,EQ]
tryResolveGeneralValue n@(Left (UnderOperation      a b))   = compareGeneralValue n a b [LT]
tryResolveGeneralValue n@(Left (DifferentOperation  a b))   = compareGeneralValue n a b [LT,GT]
tryResolveGeneralValue n@(Left (RegexpOperation     a b)) = do
    ra <- tryResolveExpression a
    rb <- tryResolveExpression b
    case (ra, rb) of
        (Right (ResolvedString src), Right (ResolvedRegexp reg)) -> do
                m <- liftIO $ regmatch src reg
                case m of
                    Right x  -> return $ Right $ ResolvedBool x
                    Left err -> throwPosError $ "Error with regexp " <> tshow reg <> ": " <> T.pack err
        (Right x, _) -> throwPosError $ "Was expecting a string to match to a regexp, not " <> tshow x
        (_, Right x) -> throwPosError $ "Was expecting a regexp, not " <> tshow x
        _            -> return n
tryResolveGeneralValue n@(Left (OrOperation a b)) = do
    ra <- tryResolveBoolean $ Left a
    if ra == Right (ResolvedBool True)
        then return $ Right $ ResolvedBool True
        else do
            rb <- tryResolveBoolean $ Left b
            case (ra, rb) of
                (_, Right (ResolvedBool True)) -> return $ Right $ ResolvedBool True
                (Right (ResolvedBool rra), Right (ResolvedBool rrb)) -> return $ Right $ ResolvedBool $ rra || rrb
                _ -> return n
tryResolveGeneralValue n@(Left (AndOperation a b)) = do
    ra <- tryResolveBoolean $ Left a
    if ra == Right (ResolvedBool False)
        then return $ Right $ ResolvedBool False
        else do
            rb <- tryResolveBoolean $ Left b
            case (ra, rb) of
                (_, Right (ResolvedBool False)) -> return $ Right $ ResolvedBool False
                (Right (ResolvedBool rra), Right (ResolvedBool rrb)) -> return $ Right $ ResolvedBool $ rra && rrb
                _ -> return n
tryResolveGeneralValue   (Left (NotOperation x)) = do
    rx <- tryResolveBoolean $ Left x
    case rx of
        Right (ResolvedBool b) -> return $ Right $ ResolvedBool $ not b
        _ -> return rx
tryResolveGeneralValue (Left (LookupOperation a b)) = do
    ra <- tryResolveExpression a
    rb <- tryResolveExpressionString b
    case (ra, rb) of
        (Right (ResolvedArray ar), Right num) -> do
            bnum <- readint num
            let nnum = fromIntegral bnum
            if length ar <= nnum
                then throwPosError ("Invalid array index " <> num <> " " <> tshow ar)
                else return $ Right (ar !! nnum)
        (Right (ResolvedHash ar), Right idx) -> do
            let filtered = filter (\(x,_) -> x == idx) ar
            case filtered of
                [] -> return $ Right ResolvedUndefined
                [(_,x)] -> return $ Right x
                x  -> throwPosError ("Hum, WTF tryResolveGeneralValue " <> tshow x)
        (_, Left y) -> throwPosError ("Could not resolve index " <> tshow y)
        (Left x, _) -> throwPosError ("Could not resolve lookup " <> tshow x)
        (Right x, _) -> throwPosError ("Could not resolve something that is not an array nor a hash, but " <> tshow x)
-- TODO : for hashes, checks the keys
-- for strings, substrings
tryResolveGeneralValue o@(Left (IsElementOperation b a)) = do
    ra <- tryResolveExpression a
    rb <- tryResolveExpressionString b
    case (ra, rb) of
        (Right (ResolvedArray ar), Right idx) ->
            let filtered = filter (compareRValues (ResolvedString idx)) ar
            in  return $! Right $! ResolvedBool $! not $! null filtered
        (Right (ResolvedHash h), Right idx) ->
            let filtered = filter (\(fa,_) -> fa == idx) h
            in  return $! Right $! ResolvedBool $! not $! null filtered
        (Right (ResolvedString _), Right _) -> throwPosError "in operator not yet implemented for substrings"
        (Right ba, Right bb) -> throwPosError $ "Expected a string and a hash, array or string for the in operator, not " <> tshow (ba,bb)
        _ -> return o
-- horrible hack, because I do not know how to supply a single operator for Int and Float
tryResolveGeneralValue o@(Left (PlusOperation a b)) = arithmeticOperation a b (+) (+) o
tryResolveGeneralValue o@(Left (MinusOperation a b)) = arithmeticOperation a b (-) (-) o
tryResolveGeneralValue o@(Left (DivOperation a b)) = arithmeticOperation a b div (/) o
tryResolveGeneralValue o@(Left (MultiplyOperation a b)) = arithmeticOperation a b (*) (*) o

tryResolveGeneralValue e = throwPosError ("tryResolveGeneralValue not implemented for " <> tshow e)

resolveGeneralValue :: GeneralValue -> CatalogMonad ResolvedValue
resolveGeneralValue e = do
    x <- tryResolveGeneralValue e
    case x of
        Left n -> throwPosError  ("Could not resolveGeneralValue " <> tshow n)
        Right p -> return p

tryResolveExpressionString :: Expression -> CatalogMonad GeneralString
tryResolveExpressionString s = do
    resolved <- tryResolveExpression s
    case resolved of
        Right e -> liftM Right (rstring e)
        Left  e -> return $ Left e

rstring :: ResolvedValue -> CatalogMonad T.Text
rstring resolved = case resolved of
        ResolvedString s -> return s
        ResolvedInt i    -> return (tshow i)
        e                -> throwPosError ("'" <> tshow e <> "' will not resolve to a string")

rstrings :: ResolvedValue -> CatalogMonad [T.Text]
rstrings resolved = case resolved of
         ResolvedString s -> return [s]
         ResolvedInt i    -> return [tshow i]
         ResolvedArray xs -> mapM rstring xs
         e                -> throwPosError ("'" <> tshow e <> "' will not resolve to a string")

resolveExpression :: Expression -> CatalogMonad ResolvedValue
resolveExpression e = do
    resolved <- tryResolveExpression e
    case resolved of
        Right r -> return r
        Left  x -> do
            p <- getPos
            throwError ("Can't resolve expression '" <> tshow x <> "' at " <> tshow p <> " was '" <> tshow e <> "'")

resolveExpressionString :: Expression -> CatalogMonad T.Text
resolveExpressionString x = do
    resolved <- resolveExpression x
    case resolved of
        ResolvedString s -> return s
        ResolvedInt i -> return (tshow i)
        e -> do
            p <- getPos
            throwError ("Can't resolve expression '" <> tshow e <> "' to a string at " <> tshow p)

tryResolveValue :: Value -> CatalogMonad GeneralValue
tryResolveValue (Literal x) = return $ Right $ ResolvedString x
tryResolveValue (Integer x) = return $ Right $ ResolvedInt x
tryResolveValue (Double  x) = return $ Right $ ResolvedDouble x
tryResolveValue (PuppetBool x) = return $ Right $ ResolvedBool x

tryResolveValue n@(ResourceReference rtype vals) = do
    rvals <- tryResolveExpression vals
    case rvals of
        Right resolved -> return $ Right $ ResolvedRReference rtype resolved
        _              -> return $ Left $ Value n
-- special variables first
tryResolveValue   (VariableReference "module_name") = liftM (\x ->
    let headname = T.takeWhile (/= ':') (head x)
    in  Right $ ResolvedString $ if T.isPrefixOf "#DEFINE#" headname
                                     then T.drop 8 headname
                                     else headname
    ) getScope
tryResolveValue   (VariableReference vname) = do
    -- TODO check scopes !!!
    curscp <- getScope
    let gvarnm sc | qualified vname = vname : remtopscope vname                 -- scope is explicit
                  | sc == "::"      = ["::" <> vname]                           -- we are toplevel
                  | otherwise       = [sc <> "::" <> vname, "::" <> vname]  -- check for local scope, then global
        varnames = concatMap gvarnm curscp
        remtopscope x | T.isPrefixOf "::" x = [T.drop 2 x]
                      | otherwise           = []
    matching <- liftM catMaybes (mapM getVariable varnames)
    if null matching
        then do
            position <- getPos
            addWarning ("Could not resolveValue variables " <> tshow varnames <> " at " <> tshow position)
            return $ Left $ Value $ VariableReference (head varnames)
        else return $ case head matching of
            (x,_) -> x

tryResolveValue   (Interpolable x) = do
    resolved <- mapM tryResolveValueString x
    if null $ lefts resolved
        then return $ Right $ ResolvedString $ T.concat $ rights resolved
        -- if it is not resolved, we will try to store it as resolved as
        -- possible, so as not to lose the context
        else fmap (Left . Value . Interpolable)
                    (mapM tryResolveValue x >>= mapM generalValue2Value)

tryResolveValue n@(PuppetHash (Parameters x)) = do
    resolvedKeys <- mapM (tryResolveExpressionString . fst) x
    resolvedValues <- mapM (tryResolveExpression . snd) x
    return $ if null (lefts resolvedKeys) && null (lefts resolvedValues)
                 then Right $ ResolvedHash $ zip (rights resolvedKeys) (rights resolvedValues)
                 else Left $ Value n

tryResolveValue n@(PuppetArray expressions) = do
    resolvedExpressions <- mapM tryResolveExpression expressions
    return $ if null $ lefts resolvedExpressions
                 then Right $ ResolvedArray $ rights resolvedExpressions
                 else Left $ Value n


tryResolveValue   (FunctionCall "generate" args) = if null args
    then throwPosError "Empty argument list in generate"
    else do
        nargs   <- mapM resolveExpressionString args
        let cmdname:cmdargs = nargs
        gens    <- liftIO $ generate cmdname cmdargs
        case gens of
            Just w  -> return $ Right $ ResolvedString w
            Nothing -> throwPosError $ "Function call generate for command " <> cmdname <> " (" <> tshow cmdargs <> ") failed"

tryResolveValue n@(FunctionCall "pdbresourcequery" (query:xs)) = do
    let
        rvalue2query :: ResolvedValue -> Either String PDB.Query
        rvalue2query (ResolvedArray (ResolvedString o : nxs)) = case PDB.getOperator o of
                                                                    Just PDB.OAnd -> fmap (PDB.Query PDB.OAnd) (mapM rvalue2query nxs)
                                                                    Just PDB.OOr  -> fmap (PDB.Query PDB.OOr)  (mapM rvalue2query nxs)
                                                                    Just PDB.ONot -> fmap (PDB.Query PDB.ONot) (mapM rvalue2query nxs)
                                                                    Just op       -> fmap (PDB.Query op)       (mapM rvalue2query' nxs)
                                                                    Nothing       -> Left $ "Can't resolve operator " ++ T.unpack o
        rvalue2query x = Left $ "Don't know what to do with " ++ T.unpack (showValue x)

        rvalue2query' :: ResolvedValue -> Either String PDB.Query
        rvalue2query' (ResolvedArray x)  = fmap PDB.Terms (mapM rvalue2string x)
        rvalue2query' x = fmap PDB.Term (rvalue2string x)
        rvalue2string :: ResolvedValue -> Either String T.Text
        rvalue2string (ResolvedString s) = Right s
        rvalue2string (ResolvedBool True) = Right "true"
        rvalue2string (ResolvedBool False) = Right "false"
        rvalue2string x = Left $ "Don't know why we had " ++ T.unpack (showValue x)
    rkey <- case xs of
                [key] -> do
                    r <- tryResolveExpression key
                    case r of
                        Right (ResolvedString keyname) -> return $ Right $ Just keyname
                        Right x                        -> throwPosError $ "The pdbresourcequery function expects a string as the second argument, not " <> showValue x
                        Left  y                        -> return $ Left y
                []    -> return $ Right Nothing
                _     -> throwPosError "Bad number of arguments for function pdbresourcequery"
    rquery <- tryResolveExpression query
    case (rquery, rkey) of
        (Right a@(ResolvedArray _), Right keyname)  -> case rvalue2query a of
                                                           Right q -> fmap Right (pdbresourcequery q keyname)
                                                           Left rr -> throwPosError ("Could not transform " <> showValue a <> " to a PuppetDB query: " <> T.pack rr)
        (Right a, Right _) -> throwPosError $ "The pdbresourcequery function expects an array as the first argument, not " <> showValue a
        _ -> return $ Left $ Value n

tryResolveValue n@(FunctionCall "is_domain_name" [x]) = do
    rx <- tryResolveExpressionString x
    case rx of
        Right s -> let
            goodpart gs = T.length gs < 64 && not (T.null gs) && isAlpha (T.head gs) && (T.all (\gx -> gx == '-' || isAlphaNum gx) gs)
            badparts "" = False
            badparts str =
                let (b,e) = T.break (=='.') str
                in case (goodpart b, e) of
                    (True , "") -> False
                    (True ,  y) -> badparts (T.tail y)
                    (False,  _) -> True
            bad = T.null s || T.length s > 255 || badparts s
            -- TODO check the parts are 63 char long
            in return $ Right $ ResolvedBool $ not bad
        _ -> return $ Left $ Value n

tryResolveValue   (FunctionCall "fqdn_rand" args) = if null args
    then throwPosError "Empty argument list in fqdn_rand call"
    else do
        nargs  <- mapM resolveExpressionString args
        curmax <- readint (head nargs)
        liftM (Right . ResolvedInt) (fqdn_rand curmax (tail nargs))
tryResolveValue   (FunctionCall "mysql_password" args) = if length args /= 1
    then throwPosError "mysql_password takes a single argument"
    else do
        es <- tryResolveExpressionString (head args)
        case es of
            Right s -> liftM (Right . ResolvedString) (mysql_password s)
            Left  u -> return $ Left u
tryResolveValue   (FunctionCall "template" [name]) = do
    fname <- tryResolveExpressionString name
    case fname of
        Left x -> throwPosError $ "Can't resolve template path " <> tshow x
        Right filename -> do
            vars <- fmap curVariables get >>= DT.mapM (\(v,p) -> fmap (\x -> (x,p)) (tryResolveGeneralValue v))
            saveVariables vars
            scp <- liftM head getScope -- TODO check if that sucks
            templatefunc <- liftM computeTemplateFunction get
            out <- liftIO (templatefunc filename scp (Map.map fst vars))
            case out of
                Right x -> return $ Right $ ResolvedString x
                Left err -> throwPosError (T.pack err)
tryResolveValue   (FunctionCall "inline_template" _) = return $ Right $ ResolvedString "TODO"
tryResolveValue   (FunctionCall "defined" [v]) = do
    rv <- tryResolveExpression v
    case rv of
        Left n -> return $ Left n
        -- TODO BUG
        Right (ResolvedString typeorclass) -> do
            ntypes <- fmap nativeTypes get
            -- is it a loaded class or a define ?
            if Map.member typeorclass ntypes
                then return $ Right $ ResolvedBool True
                else do
                    isdefine <- checkDefine typeorclass
                    case isdefine of
                        Just _  -> return $ Right $ ResolvedBool True
                        Nothing -> liftM (Right . ResolvedBool . Map.member typeorclass . curClasses) get
        Right (ResolvedRReference rtype (ResolvedString rname)) -> do
            defset <- fmap definedResources get
            return $ Right $ ResolvedBool (Map.member (rtype, rname) defset)
        Right x -> throwPosError $ "Can't know if this could be defined : " <> tshow x
tryResolveValue n@(FunctionCall "regsubst" [str, src, dst, flags]) = do
    rstr   <- tryResolveExpressionString str
    rsrc   <- tryResolveExpressionString src
    rdst   <- tryResolveExpressionString dst
    rflags <- tryResolveExpressionString flags
    case (rstr, rsrc, rdst, rflags) of
        (Right sstr, Right ssrc, Right sdst, Right sflags) -> liftM (Right . ResolvedString) (regsubst sstr ssrc sdst sflags)
        _                                                  -> return $ Left $ Value n
tryResolveValue   (FunctionCall "regsubst" [str, src, dst]) = tryResolveValue (FunctionCall "regsubst" [str, src, dst, Value $ Literal ""])
tryResolveValue   (FunctionCall "regsubst" args) = throwPosError ("Bad argument count for regsubst " <> tshow args)

tryResolveValue n@(FunctionCall "chomp" [str]) = do
    let mmychomp (ResolvedString s) = return $ ResolvedString (T.stripEnd s)
        mmychomp r                    = throwPosError $ "The chomp function expects strings or arrays of strings, not this: " <> tshow r
    rstr <- tryResolveExpression str
    case rstr of
        Left  _ -> return $ Left $ Value n
        Right (ResolvedArray  arr) -> fmap (Right . ResolvedArray) (mapM mmychomp arr)
        Right x                    -> fmap Right (mmychomp x)

tryResolveValue n@(FunctionCall "split" [str, reg]) = do
    rstr   <- tryResolveExpressionString str
    rreg   <- tryResolveExpressionString reg
    case (rstr, rreg) of
        (Right sstr, Right sreg) -> do
            sp <- liftIO $ puppetSplit sstr sreg
            case sp of
                Right o -> return $ Right $ ResolvedArray $ map ResolvedString o
                Left  r -> throwPosError $ "split error: " <> tshow r
        _                        -> return $ Left $ Value n
tryResolveValue   (FunctionCall "split" _) = throwPosError "Bad argument count for function split"
tryResolveValue n@(FunctionCall "upcase"  args) = stringTransform args n T.toUpper
tryResolveValue n@(FunctionCall "lowcase" args) = stringTransform args n T.toLower
tryResolveValue n@(FunctionCall "sha1"    args) = stringTransform args n puppetSHA1
tryResolveValue n@(FunctionCall "md5"     args) = stringTransform args n puppetMD5

tryResolveValue n@(FunctionCall "versioncmp" [a,b]) = do
    ra <- tryResolveExpressionString a
    rb <- tryResolveExpressionString b
    case (ra, rb) of
        (Right sa, Right sb)    -> return $ Right $ ResolvedInt (versioncmp sa sb)
        _                       -> return $ Left $ Value n
tryResolveValue n@(FunctionCall "file" filelist) = do
    -- resolving the list of file pathes
    rfilelist <- mapM tryResolveExpressionString filelist
    let (lf, rf) = partitionEithers rfilelist
    if null lf
        then do
            content <- liftIO $ file rf
            case content of
                Nothing -> throwPosError $ "Files " <> tshow rf <> " could not be found"
                Just x  -> return $ Right $ ResolvedString x
        else return $ Left $ Value n
tryResolveValue n@(FunctionCall "getvar" [varinfo]) = do
    varname <- tryResolveExpressionString varinfo
    case varname of
        Right s -> tryResolveValue (VariableReference s)
        Left  _ -> return $ Left $ Value n
tryResolveValue   (FunctionCall "getvar" nn) = throwPosError $ "getvar expects a single argument, not " <> tshow (length nn)
tryResolveValue n@(FunctionCall "is_string" [varinfo]) = do
    varname <- tryResolveExpression varinfo
    case varname of
        Right (ResolvedString _) -> return $ Right $ ResolvedBool True
        Right _ -> return $ Right $ ResolvedBool False
        Left _ -> return $ Left $ Value n
tryResolveValue n@(FunctionCall fname args) = do
    ufunctions <- fmap userFunctions get
    l <- fmap luaState get
    case (l, Set.member fname ufunctions) of
     (Just ls, True) -> do
        rargs <- mapM tryResolveExpression args
        if null (lefts rargs)
            then fmap Right (puppetFunc ls fname (rights rargs))
            else return $ Left $ Value n
     _               -> throwPosError ("FunctionCall " <> fname <> " not implemented")

tryResolveValue Undefined = return $ Right ResolvedUndefined
tryResolveValue (PuppetRegexp x) = return $ Right $ ResolvedRegexp x

tryResolveValue x = throwPosError ("tryResolveValue not implemented for " <> tshow x)

tryResolveValueString :: Value -> CatalogMonad GeneralString
tryResolveValueString x = do
    r <- tryResolveValue x
    case r of
        Right (ResolvedString v)   -> return $ Right v
        Right (ResolvedInt    i)   -> return $ Right (tshow i)
        Right (ResolvedDouble i)   -> return $ Right (tshow i)
        Right (ResolvedBool True)  -> return $ Right "True"
        Right (ResolvedBool False) -> return $ Right "False"
        Right v                    -> throwPosError ("Can't resolve valuestring for " <> tshow v)
        Left  v                    -> return $ Left v

getRelationParameterType :: GeneralString -> Maybe LinkType
getRelationParameterType (Right "require" )  = Just RRequire
getRelationParameterType (Right "notify"  )  = Just RNotify
getRelationParameterType (Right "before"  )  = Just RBefore
getRelationParameterType (Right "subscribe") = Just RSubscribe
getRelationParameterType _                   = Nothing

-- this function saves a new condition for collection
pushRealize :: ResolvedValue -> CatalogMonad ()
pushRealize (ResolvedRReference rtype (ResolvedString rname)) = do
    let myfunction :: CResource -> CatalogMonad Bool
        myfunction (CResource _ mcrname mcrtype _ _ _ _) = do
            srname <- resolveGeneralString mcrname
            return ((srname == rname) && (mcrtype == rtype))
    addCollect ((myfunction, Just $ PDB.queryRealize rtype rname) , Map.empty)
    return ()
pushRealize (ResolvedRReference _ x) = throwPosError (tshow x <> " was not resolved to a string")
pushRealize x                        = throwPosError ("A reference was expected instead of " <> tshow x)

executeFunction :: T.Text -> [ResolvedValue] -> CatalogMonad Catalog
executeFunction "fail" [ResolvedString errmsg] = throwPosError ("Error: " <> errmsg)
executeFunction "fail" args = throwPosError ("Error: " <> tshow args)
executeFunction "realize" rlist = mapM_ pushRealize rlist >> return []
executeFunction "dumpvariables" _ = do
    vars <- fmap curVariables get
    mapM_ (liftIO . print) (Map.toList vars)
    return []
executeFunction "create_resources" (mrtype:rdefs:rest) = do
--        applyDefaults' :: CResource -> ResDefaults -> CatalogMonad CResource
--        data ResDefaults = RDefaults String [(GeneralString, GeneralValue)] SourcePos
--
--
    mrrtype <- case mrtype of
        ResolvedString x -> return x
        _                -> throwPosError $ "Resource type must be a string and not " <> tshow mrtype
    arghash <- case rdefs of
        ResolvedHash x -> return x
        _              -> throwPosError $ "Resource definition must be a hash, and not " <> tshow rdefs
    position <- getPos
    defaults <- case rest of
                    [ResolvedHash h] -> return $ RDefaults mrrtype (Map.fromList $ map (Right *** Right) h) position
                    []  -> return $ RDefaults mrrtype Map.empty position
                    _   -> throwPosError ("Bad many arguments to create_resources: " <> tshow rest)
    let prestatements = map (\(rname, rargs) -> (Value $ Literal rname, resolved2expression rargs)) arghash
    resources <- mapM (\(resname, pval) -> do
            realargs <- case pval of
                Value (PuppetHash (Parameters h)) -> return h
                _                    -> throwPosError "This should not happen, create_resources argument is not a hash"
            return $ Resource mrrtype resname realargs Normal position
        ) prestatements
    liftM concat (mapM evaluateStatements resources) >>= mapM (\r -> applyDefaults' r defaults)
executeFunction "create_resources" x = throwPosError ("Bad arguments to create_resources: " <> tshow x)
executeFunction "validate_array" [x] = case x of
    ResolvedArray _ -> return []
    y               -> throwPosError $ tshow y <> " is not an array"
executeFunction "validate_hash" [x] = case x of
    ResolvedHash _ -> return []
    y              -> throwPosError $ tshow y <> " is not a hash"
executeFunction "validate_string" [x] = case x of
    ResolvedString _ -> return []
    y                -> throwPosError $ tshow y <> " is not an string"
executeFunction "validate_re" [x,re] = case (x,re) of
    (ResolvedString z, ResolvedString rre) -> do
        m <- liftIO $ regmatch z rre
        case m of
            Right True  -> return []
            Right False -> throwPosError $ tshow x <> " does not match the regexp " <> tshow rre
            Left err    -> throwPosError $ "Error with regexp " <> tshow rre <> ": " <> T.pack err
    (y,z) -> throwPosError $ "Can't compare " <> tshow y <> " to regexp " <> tshow z
executeFunction "validate_bool" [x] = case x of
    ResolvedBool _ -> return []
    y              -> throwPosError $ tshow y <> " is not a boolean"
executeFunction fname args = do
    ufunctions <- fmap userFunctions get
    l <- fmap luaState get
    case (l, Set.member fname ufunctions) of
     (Just ls, True) -> do
         o <- puppetFunc ls fname args
         case o of
             ResolvedBool True  -> return []
             ResolvedBool False -> throwPosError ("Function " <> fname <> "(" <> tshow args <> ") returned false")
             x                  -> throwPosError ("Function " <> fname <> "(" <> tshow args <> ") did not return a bool: " <> tshow x)
     _               -> do
         position <- getPos
         addWarning $ "Function " <> fname <> "(" <> tshow args <> ") not handled at " <> tshow position
         return []

compareExpression :: Expression -> Expression -> CatalogMonad (Maybe Ordering)
compareExpression a b = do
    ra <- tryResolveExpression a
    rb <- tryResolveExpression b
    case (ra, rb) of
        (Right rra, Right rrb) -> return $ Just $ compareValues rra rrb
        _ -> return $ compareSemiResolved ra rb

compareSemiResolved :: GeneralValue -> GeneralValue -> Maybe Ordering
compareSemiResolved a@(Right _) b@(Left _) = compareSemiResolved b a
compareSemiResolved (Left (Value (VariableReference _))) (Left (Value (VariableReference _))) = Just EQ
compareSemiResolved (Left (Value (VariableReference _))) (Left (Value (Literal "")))          = Just EQ
compareSemiResolved (Left (Value (VariableReference _))) (Left (Value (Literal "false")))     = Just EQ
compareSemiResolved a b                                                                       = Just (compare a b)

compareGeneralValue :: GeneralValue -> Expression -> Expression -> [Ordering] -> CatalogMonad GeneralValue
compareGeneralValue n a b acceptable = do
    cmp <- compareExpression a b
    case cmp of
        Nothing -> return n
        Just x  -> return $ Right $ ResolvedBool (x `elem` acceptable)
compareValues :: ResolvedValue -> ResolvedValue -> Ordering
compareValues (ResolvedString s) (ResolvedBool b)  = case (s,b) of
                                                         ("true", True)   -> EQ
                                                         ("false", False) -> EQ
                                                         _                -> LT
compareValues a@(ResolvedBool _)   b@(ResolvedString _) = compareValues b a
compareValues a@(ResolvedString _) b@(ResolvedInt _) = compareValues b a
compareValues   (ResolvedInt a)      (ResolvedString b) = case readDecimal b of
                                                              Right bi -> compare a bi
                                                              _ -> LT
compareValues (ResolvedString a) (ResolvedRegexp b) = case unsafePerformIO (regmatch a b) of
                                                          Right True  -> EQ
                                                          _           -> LT
compareValues (ResolvedString a)   (ResolvedString b)   = comparing T.toCaseFold a b
compareValues x y = compare x y

compareRValues :: ResolvedValue -> ResolvedValue -> Bool
compareRValues a b = compareValues a b == EQ

-- used to handle the special cases when we know it is a boolean context
tryResolveBoolean :: GeneralValue -> CatalogMonad GeneralValue
tryResolveBoolean v = do
    rv <- tryResolveGeneralValue v
    case rv of
        Left BFalse                     -> return $ Right $ ResolvedBool False
        Left BTrue                      -> return $ Right $ ResolvedBool True
        Right (ResolvedString "")       -> return $ Right $ ResolvedBool False
        Right (ResolvedString _)        -> return $ Right $ ResolvedBool True
        Right (ResolvedInt _)           -> return $ Right $ ResolvedBool True
        Right  ResolvedUndefined        -> return $ Right $ ResolvedBool False
        Right (ResolvedArray _)         -> return $ Right $ ResolvedBool True
        Right (ResolvedRReference _ _)  -> return $ Right $ ResolvedBool True
        Left (Value (VariableReference _)) -> return $ Right $ ResolvedBool False
        Left (EqualOperation (Value (VariableReference _)) (Value (Literal ""))) -> return $ Right $ ResolvedBool True -- case where a variable was not resolved and compared to the empty string
        Left (EqualOperation (Value (VariableReference _)) (Value (Literal "true"))) -> return $ Right $ ResolvedBool False -- case where a variable was not resolved and compared to the string "true"
        Left (EqualOperation (Value (VariableReference _)) (Value (Literal "false"))) -> return $ Right $ ResolvedBool True -- case where a variable was not resolved and compared to the string "false"
        _ -> return rv

resolveBoolean :: GeneralValue -> CatalogMonad Bool
resolveBoolean v = do
    rv <- tryResolveBoolean v
    case rv of
        Right (ResolvedBool x) -> return x
        n -> throwPosError ("Could not resolve " <> tshow n <> "(was " <> tshow rv <> ") as a boolean")

resolveGeneralString :: GeneralString -> CatalogMonad T.Text
resolveGeneralString (Right x) = return x
resolveGeneralString (Left y) = resolveExpressionString y

collectionFunction :: Virtuality -> T.Text -> Expression -> CatalogMonad (CResource -> CatalogMonad Bool, Maybe PDB.Query)
collectionFunction virt mrtype exprs = do
    (finalfunc, pdbquery) <- case exprs of
        BTrue -> return (\_ -> return True, Just (PDB.collectAll mrtype))
        EqualOperation a b -> do
            ra <- resolveExpression a
            rb <- resolveExpression b
            paramname <- case ra of
                ResolvedString pname -> return pname
                _ -> throwPosError "We only support collection of the form 'parameter == value'"
            defstatement <- checkDefine mrtype
            paramset <- case defstatement of
                Nothing -> fmap nativeTypes get >>= \nt -> case Map.lookup mrtype nt of
                    Just (PuppetTypeMethods _ ps) -> return ps
                    Nothing -> throwPosError $ "Unknown type " <> mrtype <> " when trying to collect"
                Just (DefineDeclaration _ params _ _) -> return $ Set.fromList $ map fst params
                Just x -> throwPosError $ "Expected a DefineDeclaration here instead of " <> tshow x
            when (Set.notMember paramname paramset && not (Set.member paramname metaparameters)) $
                throwPosError $ "Parameter " <> paramname <> " is not a valid parameter. It should be in : " <> tshow (Set.toList paramset)
            return (\r ->
                case Map.lookup (Right paramname) (crparams r) of
                    Nothing -> return False
                    Just prmmatch -> do
                        cmp <- resolveGeneralValue prmmatch
                        case (paramname, cmp) of
                            ("tag", ResolvedArray xs) ->
                                let filtered = filter (compareRValues rb) xs
                                in  return $ not $ null filtered
                            _ -> return $ compareRValues cmp rb
                , case (paramname, rb) of
                      ("tag", ResolvedString tagval) -> Just (PDB.collectTag mrtype tagval)
                      (param, ResolvedString prmval) -> Just (PDB.collectParam mrtype param prmval)
                      _                              -> Nothing
                )
        x -> throwPosError $ "TODO : implement collection function for " <> tshow x
    return (\res ->
        -- <| |> matches Normal resources
        if (crtype res == mrtype) && ( ((virt == Virtual) &&  (crvirtuality res == Normal)) || (crvirtuality res == virt))
            then finalfunc res
            else return False
        , if virt == Exported
              then pdbquery
              else Nothing
        )


generalValue2Expression :: GeneralValue -> Expression
generalValue2Expression (Left x) = x
generalValue2Expression (Right y) = resolved2expression y

generalValue2Value :: GeneralValue -> CatalogMonad Value
generalValue2Value x = case generalValue2Expression x of
                           (Value z) -> return z
                           y         -> throwPosError $ "Could not downgrade this to a value: " <> tshow y

resolved2expression :: ResolvedValue -> Expression
resolved2expression (ResolvedString str) = Value $ Literal str
resolved2expression (ResolvedInt i) = Value $ Integer i
resolved2expression (ResolvedBool True) = BTrue
resolved2expression (ResolvedBool False) = BFalse
resolved2expression (ResolvedRReference mrtype name) = Value $ ResourceReference mrtype (resolved2expression name)
resolved2expression (ResolvedArray vals) = Value $ PuppetArray $ map resolved2expression vals
resolved2expression (ResolvedHash hash) = Value $ PuppetHash $ Parameters $ map (\(s,v) -> (Value $ Literal s, resolved2expression v)) hash
resolved2expression  ResolvedUndefined = Value Undefined
resolved2expression (ResolvedRegexp a) = Value $ PuppetRegexp a
resolved2expression (ResolvedDouble d) = Value $ Double d

arithmeticOperation :: Expression -> Expression -> (Integer -> Integer -> Integer) -> (Double -> Double -> Double) -> GeneralValue -> CatalogMonad GeneralValue
arithmeticOperation a b opi opf def = do
    ra <- tryResolveExpression a
    rb <- tryResolveExpression b
    case (ra, rb) of
        (Right (ResolvedInt sa)   , Right (ResolvedInt    sb)) -> return $ Right $ ResolvedInt $ opi sa sb
        (Right (ResolvedDouble sa), Right (ResolvedInt    sb)) -> return $ Right $ ResolvedDouble $ opf sa (fromIntegral sb)
        (Right (ResolvedInt sa)   , Right (ResolvedDouble sb)) -> return $ Right $ ResolvedDouble $ opf (fromIntegral sa) sb
        (Right (ResolvedDouble sa), Right (ResolvedDouble sb)) -> return $ Right $ ResolvedDouble $ opf sa sb
        _ -> return def


stringTransform :: [Expression] -> Value -> (T.Text -> T.Text) -> CatalogMonad GeneralValue
stringTransform [u] n f = do
    r <- tryResolveExpressionString u
    case r of
        Right s -> return $ Right $ ResolvedString $ f s
        Left _  -> return $ Left $ Value n
stringTransform _ _ _ = throwPosError "This function takes a single argument."
