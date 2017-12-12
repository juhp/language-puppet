{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE GADTs #-}
module Puppet.Interpreter.PrettyPrinter(containerComma) where

import           Puppet.Prelude               hiding (empty, (<$>))

import           Data.Aeson                   (ToJSON, encode)
import qualified Data.ByteString.Lazy.Char8   as BSL
import qualified Data.HashMap.Strict          as HM
import qualified Data.HashSet                 as HS
import qualified Data.Text                    as Text
import qualified Data.Vector                  as V
import qualified GHC.Exts                     as Exts
import           Text.PrettyPrint.ANSI.Leijen ((<$>))

import           Puppet.Interpreter.Types
import           Puppet.Parser.PrettyPrinter
import           Puppet.Parser.Types
import           Puppet.PP

containerComma'' :: Pretty a => [(Doc, a)] -> Doc
containerComma'' x = indent 2 ins
    where
        ins = mconcat $ intersperse (comma <$> empty) (fmap showC x)
        showC (a,b) = a <+> text "=>" <+> pretty b

containerComma' :: Pretty a => [(Doc, a)] -> Doc
containerComma' = braces . containerComma''

containerComma :: Pretty a => Container a -> Doc
containerComma hm = containerComma' (fmap (\(a,b) -> (fill maxalign (pretty a), b)) hml)
    where
        hml = HM.toList hm
        maxalign = maximum (fmap (Text.length . fst) hml)

instance Pretty Text where
    pretty = ttext

instance Pretty PValue where
    pretty (PBoolean True)  = dullmagenta $ text "true"
    pretty (PBoolean False) = dullmagenta $ text "false"
    pretty (PString s) = dullcyan (ttext (stringEscape s))
    pretty (PNumber n) = cyan (ttext (scientific2text n))
    pretty PUndef = dullmagenta (text "undef")
    pretty (PResourceReference t n) = capitalize t <> brackets (text (Text.unpack n))
    pretty (PArray v) = list (map pretty (V.toList v))
    pretty (PHash g) = containerComma g
    pretty (PType dt) = pretty dt

instance Pretty TopLevelType where
    pretty TopNode   = dullyellow (text "node")
    pretty TopDefine = dullyellow (text "define")
    pretty TopClass  = dullyellow (text "class")

instance Pretty RIdentifier where
    pretty (RIdentifier t n) = pretty (PResourceReference t n)

meta :: Resource -> Doc
meta r = showPPos (r ^. rpos) <+> green (node <+> brackets scp)
    where
        node = red (ttext (r ^. rnode))
        scp = "Scope" <+> pretty (r ^.. rscope . folded . filtered (/=ContRoot) . to pretty)

resourceBody :: Resource -> Doc
resourceBody r = virtuality <> blue (ttext (r ^. rid . iname)) <> ":" <+> meta r <$> containerComma'' insde <> ";"
        where
           virtuality = case r ^. rvirtuality of
                            Normal           -> empty
                            Virtual          -> dullred "@"
                            Exported         -> dullred "@@"
                            ExportedRealized -> dullred "<@@>"
           insde = alignlst dullblue attriblist1 ++ alignlst dullmagenta attriblist2
           alignlst col = map (first (fill maxalign . col . ttext))
           attriblist1 = Exts.sortWith fst $ HM.toList (r ^. rattributes) ++ aliasdiff
           aliasWithoutTitle = r ^. ralias & contains (r ^. rid . iname) .~ False
           aliasPValue = aliasWithoutTitle & PArray . V.fromList . map PString . HS.toList
           aliasdiff | HS.null aliasWithoutTitle = []
                     | otherwise = [("alias", aliasPValue)]
           attriblist2 = map totext (resourceRelations r)
           totext (RIdentifier t n, lt) = (rel2text lt , PResourceReference t n)
           maxalign = max (maxalign' attriblist1) (maxalign' attriblist2)
           maxalign' [] = 0
           maxalign' x  = maximum . map (Text.length . fst) $ x

resourceRelations :: Resource -> [(RIdentifier, LinkType)]
resourceRelations = concatMap expandSet . HM.toList . view rrelations
    where
        expandSet (ri, lts) = [(ri, lt) | lt <- HS.toList lts]

instance Pretty Resource where
    prettyList lst =
       let grouped = HM.toList $ HM.fromListWith (++) [ (r ^. rid . itype, [r]) | r <- lst ] :: [ (Text, [Resource]) ]
           sorted = Exts.sortWith fst (map (second (Exts.sortWith (view (rid.iname)))) grouped)
           showGroup :: (Text, [Resource]) -> Doc
           showGroup (rt, res) = dullyellow (ttext rt) <+> lbrace <$> indent 2 (vcat (map resourceBody res)) <$> rbrace
       in  vcat (map showGroup sorted)
    pretty r = dullyellow (ttext (r ^. rid . itype)) <+> lbrace <$> indent 2 (resourceBody r) <$> rbrace

instance Pretty CurContainerDesc where
    pretty (ContImport  p x) = magenta "import" <> braces (ttext p) <> braces (pretty x)
    pretty (ContImported x) = magenta "imported" <> braces (pretty x)
    pretty ContRoot = dullyellow (text "::")
    pretty (ContClass cname) = dullyellow (text "class") <+> dullgreen (text (Text.unpack cname))
    pretty (ContDefine dtype dname _) = pretty (PResourceReference dtype dname)

instance Pretty ResDefaults where
    pretty (ResDefaults t _ v p) = capitalize t <+> showPPos p <$> containerComma v

instance Pretty ResourceModifier where
    pretty (ResourceModifier rt ModifierMustMatch RealizeVirtual (REqualitySearch "title" (PString x)) _ p) = "realize" <> parens (pretty (PResourceReference rt x)) <+> showPPos p
    -- pretty (ResourceModifier rt ModifierCollector ct (REqualitySearch _ (PString x))  _ p) =  "collect" <> parens (pretty (PResourceReference rt x)) <+> showPPos p
    pretty _ = "TODO pretty ResourceModifier"

instance Pretty RSearchExpression where
    pretty (REqualitySearch a v) = ttext a <+> "==" <+> pretty v
    pretty (RNonEqualitySearch a v) = ttext a <+> "!=" <+> pretty v
    pretty (RAndSearch a b) = parens (pretty a) <+> "&&" <+> parens (pretty b)
    pretty (ROrSearch a b) = parens (pretty a) <+> "||" <+> parens (pretty b)
    pretty RAlwaysTrue = mempty

pf :: Doc -> [Doc] -> Doc
pf fn args = bold (red fn) <> tupled (map pretty args)

showQuery :: ToJSON a => Query a -> Doc
showQuery = string . BSL.unpack . encode

instance Pretty (InterpreterInstr a) where
    pretty PuppetPaths = pf "PuppetPathes" []
    pretty RebaseFile = pf "RebaseFile" []
    pretty IsStrict = pf "IsStrict" []
    pretty GetNativeTypes = pf "GetNativeTypes" []
    pretty (GetStatement tlt nm) = pf "GetStatement" [pretty tlt,ttext nm]
    pretty (ComputeTemplate fn _) = pf "ComputeTemplate" [fn']
        where
            fn' = case fn of
                      Left content -> pretty (PString content)
                      Right filena -> ttext filena
    pretty (ExternalFunction fn args)  = pf (ttext fn) (map pretty args)
    pretty GetNodeName                 = pf "GetNodeName" []
    pretty (HieraQuery _ q _)          = pf "HieraQuery" [ttext q]
    pretty GetCurrentCallStack         = pf "GetCurrentCallStack" []
    pretty (ErrorThrow rr)             = pf "ErrorThrow" [getError rr]
    pretty (ErrorCatch _ _)            = pf "ErrorCatch" []
    pretty (WriterTell t)              = pf "WriterTell" (map (pretty . view _2) t)
    pretty (WriterPass _)              = pf "WriterPass" []
    pretty (WriterListen _)            = pf "WriterListen" []
    pretty PDBInformation              = pf "PDBInformation" []
    pretty (PDBReplaceCatalog _)       = pf "PDBReplaceCatalog" ["..."]
    pretty (PDBReplaceFacts _)         = pf "PDBReplaceFacts" ["..."]
    pretty (PDBDeactivateNode n)       = pf "PDBDeactivateNode" [ttext n]
    pretty (PDBGetFacts q)             = pf "PDBGetFacts" [showQuery q]
    pretty (PDBGetResources q)         = pf "PDBGetResources" [showQuery q]
    pretty (PDBGetNodes q)             = pf "PDBGetNodes" [showQuery q]
    pretty PDBCommitDB                 = pf "PDBCommitDB" []
    pretty (PDBGetResourcesOfNode n q) = pf "PDBGetResourcesOfNode" [ttext n, showQuery q]
    pretty (ReadFile f)                = pf "ReadFile" (map ttext f)
    pretty (TraceEvent e)              = pf "TraceEvent" [string e]
    pretty (IsIgnoredModule m)         = pf "IsIgnoredModule" [ttext m]
    pretty (IsExternalModule m)        = pf "IsExternalModule" [ttext m]

instance Pretty LinkInformation where
    pretty (LinkInformation lsrc ldst ltype lpos) = pretty lsrc <+> pretty ltype <+> pretty ldst <+> showPPos lpos

instance Pretty DataType where
  pretty t = case t of
               DTType              -> "Type"
               DTString ma mb      -> bounded "String" ma mb
               DTInteger ma mb     -> bounded "Integer" ma mb
               DTFloat ma mb       -> bounded "Float" ma mb
               DTBoolean           -> "Boolean"
               DTArray dt mi mmx   -> "Array" <> list (pretty dt : pretty mi : maybe [] (pure . pretty) mmx)
               DTHash kt dt mi mmx -> "Hash" <> list (pretty kt : pretty dt : pretty mi : maybe [] (pure . pretty) mmx)
               DTUndef             -> "Undef"
               DTScalar            -> "Scalar"
               DTData              -> "Data"
               DTOptional o        -> "Optional" <> brackets (pretty o)
               NotUndef            -> "NotUndef"
               DTVariant vs        -> "Variant" <> list (foldMap (pure . pretty) vs)
               DTPattern vs        -> "Pattern" <> list (foldMap (pure . pretty) vs)
               DTEnum tx           -> "Enum" <> list (foldMap (pure . pretty) tx)
               DTAny               -> "Any"
               DTCollection        -> "Collection"
    where
      bounded :: (Pretty a, Pretty b) => Doc -> Maybe a -> Maybe b -> Doc
      bounded s ma mb = s <> case (ma, mb) of
                               (Just a, Nothing) -> list [pretty a]
                               (Just a, Just b)  -> list [pretty a, pretty b]
                               _                 -> mempty
