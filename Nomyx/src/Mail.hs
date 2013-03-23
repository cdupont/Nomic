{-# LANGUAGE OverloadedStrings, ExtendedDefaultRules, OverloadedStrings, NamedFieldPuns#-}


module Mail where

import Text.Blaze.Html5 hiding (map, label, br)
import qualified Text.Blaze.Html5 as H
import Text.Blaze.Html.Renderer.String
import Network.Mail.Mime hiding (mailTo)
import Prelude hiding (div, (.))
import Text.Reform.Happstack()
import Control.Monad
import Types
import Language.Nomyx.Expression
import Data.Text(Text, pack)
import Control.Concurrent
import Data.Maybe
import Utils
import Control.Exception
import qualified Data.Text.Lazy as B
import qualified Language.Haskell.HsColour.HTML as HSC
import Language.Haskell.HsColour.Colourise hiding (string)
import Text.Blaze.Internal
import Data.Lens
import Control.Category
default (Integer, Double, Data.Text.Text)


sendMail :: String -> String -> String -> IO()
sendMail to object body = do
   putStrLn $ "sending a mail to " ++ to
   forkIO $ simpleMail (Address Nothing (pack to)) (Address (Just "Nomyx Game") "Nomyx.Game@gmail.com") (pack object) "" (B.pack body) [] >>= renderSendMail
   putStrLn $ "done"
   return ()

newRuleBody :: PlayerName -> SubmitRule -> PlayerName -> Network -> Html
newRuleBody playerName (SubmitRule name desc code) prop net = docTypeHtml $ do
   (toHtml $ "Dear " ++ playerName ++ ",") >> H.br
   (toHtml $ "a new rule has been proposed by player " ++ prop ++ ".") >> H.br
   (toHtml $ "Name: " ++ name) >> H.br
   (toHtml $ "Description: " ++ desc) >> H.br
   (toHtml $ "Code: ") >> H.br >> (preEscapedString $ HSC.hscolour defaultColourPrefs False $ code) >> H.br >> H.br
   (toHtml $ "Please login into Nomyx for actions on this rule:") >> H.br
   (toHtml $ nomyxURL net ++ "/Nomyx") >> H.br >> H.br
   (toHtml $ "You received this mail because you subscribed to Nomyx. To stop receiving mails, login to Nomyx with the above address, go to Settings and uncheck the corresponding box.") >> H.br

newRuleObject :: PlayerName -> String
newRuleObject name = "[Nomyx] New rule posted by player " ++ name ++ "!"

sendMailsNewRule :: Multi -> SubmitRule -> PlayerNumber -> IO()
sendMailsNewRule m sr pn = do
   evaluate m
   let g = fromJust $ getPlayersGame pn m
   let proposer = getPlayersName pn m
   let pls = [ p { _mPlayerNumber = mypn} | p <- _mPlayers m, mypn <- map _playerNumber $ players ^$ g]
   forM_ pls $ send proposer
   where
      send :: PlayerName -> PlayerMulti -> IO()
      send prop pm = when (mailNewRule ^$ mMail ^$ pm)
          $ sendMail (mailTo ^$ mMail ^$ pm) (newRuleObject prop) (renderHtml $ newRuleBody (mPlayerName ^$ pm) sr prop (net ^$ mSettings ^$ m))

   
mapMaybeM :: (Monad m) => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f = liftM catMaybes . mapM f

getOutputs :: Multi -> [Output]
getOutputs m = concatMap _outputs $ _games m

newRulebody :: Rule -> String
newRulebody (Rule {_rNumber, _rProposedBy}) = "Rule number " ++ (show _rNumber) ++ " has been proposed by player " ++ (show _rProposedBy)



