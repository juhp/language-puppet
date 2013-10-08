module Main where

import Control.Monad
import System.FilePath.Glob
import Puppet.Parser
import Text.Parsec
import System.Environment
import Puppet.Parser.PrettyPrinter
import Text.PrettyPrint.ANSI.Leijen
import System.Posix.Terminal
import System.Posix.Types
import System.IO
import qualified Data.Text.IO as T

allchecks :: IO ()
allchecks = do
    filelist <- fmap (head . fst) (globDir [compile "*.pp"] "tests/lexer")
    testres <- mapM testparser filelist
    let testsrs = map fst testres
        isgood = all snd testres
        outlist = zip [1..(length testres)] testsrs
    mapM_ (\(n,t) -> putStrLn $ show n ++ " " ++ t) outlist
    unless isgood (error "fail")

-- returns errors
testparser :: FilePath -> IO (String, Bool)
testparser fp = do
    T.readFile fp >>= runParserT puppetParser () fp >>= \case
        Right _ -> return ("PASS", True)
        Left rr -> return (show rr, False)

check :: String -> IO ()
check fname = do
    putStr fname
    putStr ": "
    res <- T.readFile fname >>= runParserT puppetParser () fname
    is <- queryTerminal (Fd 1)
    let rfunc = if is
                    then renderPretty 0.2 200
                    else renderCompact
    case res of
        Left rr -> print rr
        Right x -> do
            putStrLn ""
            displayIO stdout (rfunc (pretty (ppStatements x)))
            putStrLn ""

main :: IO ()
main = do
    args <- getArgs
    if null args
        then allchecks
        else mapM_ check args