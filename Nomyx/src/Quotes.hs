-----------------------------------------------------------------------------
--
-- Module      :  Quotes
-- Copyright   :
-- License     :  BSD3
--
-- Maintainer  :  corentin.dupont@gmail.com
-- Stability   :
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}

module Quotes where

import Language.Haskell.TH as TH
import Language.Haskell.TH.Quote
import Language.Haskell.Interpreter hiding (get)
import Interpret


-- This quasi quoter allows to type check a string as a Nomyx rule (a RuleFunc).
-- this gives additionnal safety at compile time.
#ifdef NO_INTERPRET_QUOTES
cr :: QuasiQuoter
cr = QuasiQuoter { quoteExp  = \s -> [| s |],
                   quotePat  = undefined,
                   quoteType = undefined,
                   quoteDec  = undefined}
#else
cr :: QuasiQuoter
cr = QuasiQuoter { quoteExp  = quoteRuleFunc,
                   quotePat  = undefined,
                   quoteType = undefined,
                   quoteDec  = undefined}
#endif

quoteRuleFunc :: String -> Q TH.Exp
quoteRuleFunc s = do
   res <- runIO $ runInterpreter $ do
      setImports unQualImports
      typeOf s
   case res of
      Right "Nomex RuleResp" -> [| s |]
      Right "RuleFunc" -> [| s |]
      Right a -> fail $ "Rule doesn't typecheck: " ++ (show a)
      Left e -> fail $ show e



