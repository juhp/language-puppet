module PuppetDB.Query.Parser where

import PuppetDB.Query
import Text.Parsec hiding ((<|>))
import Text.Parsec.String
import Control.Applicative hiding (many)

quotedvariable :: Parser String
quotedvariable = (char '"' *> many (noneOf "\"") <* symbol "\"") <?> "Quoted value"

literalvariable :: Parser String
literalvariable = many (alphaNum) <?> "Literal value"

fieldlist :: Parser [String]
fieldlist = (symbol "[" *> (qvar `sepBy` symbol ",") <* symbol "]") <?> "Field list"

fields :: Parser [String]
fields = fieldlist <|> fmap (return) qvar <?> "Fields"

qvar :: Parser String
qvar = quotedvariable <|> literalvariable <?> "Value"

operator :: Parser Operator
operator = do
    v <- qvar
    case v of
        "="     -> return OEqual
        ">"     -> return OOver
        "<"     -> return OUnder
        ">="    -> return OOverE
        "<="    -> return OUnderE
        "and"   -> return OAnd
        "or"    -> return OOr
        "not"   -> return ONot
        _       -> unexpected "Operator"

matcher :: Parser Matcher
matcher = do
    symbol "["
    op <- operator
    symbol ","
    fds <- fields
    symbol ","
    vl <- qvar
    symbol "]"
    return $ Matcher op fds vl

qstring :: String -> Parser ()
qstring s = try $ do
    char '"'
    string s
    char '"'
    spaces

symbol :: String -> Parser ()
symbol s = try (string s) >> spaces

queryType :: Parser QueryType
queryType
    =   (qstring "and" >> return QAnd)
    <|> (qstring "or"  >> return QOr )
    <|> (qstring "not" >> return QNot)
    <?> "Query type"

parser :: Parser Query
parser = Query
    <$> (symbol "[" *> queryType <* symbol ",")
    <*> ((matcher `sepBy` symbol ",") <* symbol "]")

doParse :: String -> Either String Query
doParse = runP parser () "input"
