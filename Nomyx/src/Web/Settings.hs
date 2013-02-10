{-# LANGUAGE OverloadedStrings, ExtendedDefaultRules, OverloadedStrings, NamedFieldPuns#-}


module Web.Settings where

import Text.Blaze.Html5 hiding (map, label, br)
import Text.Blaze.Html5.Attributes hiding (dir, id, label)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Network.Mail.Mime hiding (mailTo)
import Prelude hiding (div)
import Text.Reform
import Text.Reform.Blaze.String hiding (form)
import Text.Reform.Happstack()
import Control.Applicative
import Control.Monad
import Types
import Web.Common
import Control.Monad.State
import Language.Nomyx.Expression
import Web.Routes.Site
import Web.Routes.PathInfo
import Web.Routes.Happstack
import Web.Routes.RouteT
import Text.Blaze.Internal
import Data.Text(Text, pack)
import Control.Concurrent
import Data.List
import Data.Maybe
import Control.Concurrent.STM
import qualified Data.Text.Lazy as B
import Multi
default (Integer, Double, Data.Text.Text)



mailForm :: (Maybe MailSettings) -> NomyxForm MailSettings
mailForm (Just (MailSettings {mailTo, mailNewRule})) = mailForm' mailTo mailNewRule
mailForm Nothing = mailForm' "" True

mailForm':: String -> Bool -> NomyxForm MailSettings
mailForm' mailTo mailNewRule = pure MailSettings <*> label "Please enter your mail: " ++> inputText mailTo <++ br
                             <*> pure True --label " send mail on new input needed from you: " ++> inputCheckbox True <++ label " " <++ br
                             <*> inputCheckbox mailNewRule <++ label " I want to be notified by email if a player proposes a new rule (recommended)" <++ br
                             <*> pure True --label " send mail on new output: " ++> inputCheckbox True <++ label " "
                             <*> pure True

settingsPage :: PlayerNumber -> MailSettings -> RoutedNomyxServer Html
settingsPage pn ms = do
   settingsLink <- showURL (SubmitSettings pn)
   mf <- lift $ viewForm "user" $ mailForm (Just ms)
   mainPage (blazeForm mf settingsLink)
             "Player settings"
             "Player settings"
             False


