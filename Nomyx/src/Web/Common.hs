{-# LANGUAGE TemplateHaskell, OverloadedStrings, GADTs, ScopedTypeVariables#-}

module Web.Common where


import Prelude hiding (div, catch)
import Text.Blaze.Html5 hiding (map, output)
import Text.Blaze.Html5.Attributes hiding (dir, id)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Web.Routes.PathInfo
import Web.Routes.RouteT
import Web.Routes.TH (derivePathInfo)
import Control.Monad.State
import Control.Concurrent.STM
import Language.Nomyx.Expression
import Happstack.Server
import Types
import qualified Data.ByteString.Char8 as C
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Text.Reform.Happstack()
import Text.Reform
import Text.Reform.Blaze.String()
import Text.Reform.Happstack()
import qualified Text.Reform.Generalized as G
import Data.Text(Text, pack)
import Web.Routes.Happstack()
import Data.Time
import Serialize
import Control.Exception
import Data.Maybe
import Utils
import Multi
default (Integer, Double, Data.Text.Text)


data LoginPass = LoginPass { login :: PlayerName,
                             password :: PlayerPassword}
                             deriving (Show, Eq)


-- | associate a player number with a handle
data PlayerClient = PlayerClient PlayerNumber deriving (Eq, Show)

-- | A structure to hold the active games and players
data Server = Server [PlayerClient] deriving (Eq, Show)


data PlayerCommand = Login
                   | PostLogin
                   | NewPlayer       LoginPass
                   | NewPlayerLogin  LoginPass
                   | Noop            PlayerNumber
                   | JoinGame        PlayerNumber GameName
                   | LeaveGame       PlayerNumber
                   | SubscribeGame   PlayerNumber GameName
                   | UnsubscribeGame PlayerNumber GameName
                   | DoInputChoice   PlayerNumber EventNumber
                   | DoInputString   PlayerNumber String
                   | NewRule         PlayerNumber
                   | NewGame         PlayerNumber
                   | Upload          PlayerNumber
                   | Settings        PlayerNumber
                   | SubmitSettings  PlayerNumber
                   deriving (Show)

$(derivePathInfo ''PlayerCommand)
$(derivePathInfo ''LoginPass)

instance PathInfo Bool where
  toPathSegments i = [pack $ show i]
  fromPathSegments = pToken (const "bool") (checkBool . show)
   where checkBool str =
           case reads str of
             [(n,[])] -> Just n
             _ ->        Nothing

modDir :: FilePath
modDir = "modules"

type NomyxServer       = ServerPartT IO
type RoutedNomyxServer = RouteT PlayerCommand NomyxServer


evalCommand :: (TVar Multi) -> State Multi a -> RoutedNomyxServer a
evalCommand tm sm = do
    m <- liftRouteT $ lift $ atomically $ readTVar tm
    return $ evalState sm m

execCommand_ :: (TVar Multi) -> PlayerNumber -> StateT Multi IO a -> RoutedNomyxServer ()
execCommand_ tm pn sm = do
    m <- liftRouteT $ lift $ atomically $ readTVar tm
    m' <- liftRouteT $ lift $ (execStateT sm m) `catch` commandExceptionHandler pn m
    liftRouteT $ lift $ atomically $ writeTVar tm m'


webCommand :: (TVar Multi) -> PlayerNumber -> MultiEvent -> RoutedNomyxServer ()
webCommand tm pn me = do
   t <- liftRouteT $ lift $ getCurrentTime
   execCommand_ tm pn (update $ TE t me)

commandExceptionHandler :: PlayerNumber -> Multi -> ErrorCall -> IO Multi
commandExceptionHandler pn m e = do
   let g = fromJust $ getPlayersGame pn m
   let g' = execState (output ("Error in command: " ++ (show e)) pn) g
   putStrLn $ "Error in command: " ++ (show e)
   return $ execState (modifyGame g') m

blazeResponse :: Html -> Response
blazeResponse html = toResponseBS (C.pack "text/html;charset=UTF-8") $ renderHtml html

blazeForm :: Html -> Text -> Html
blazeForm html link =
    H.form ! A.action (toValue link)
         ! A.method "POST"
         ! A.enctype "multipart/form-data" $
            do html
               input ! A.type_ "submit" ! A.value "Submit"

-- | Create a group of radio elements without BR between elements
inputRadio' :: (Functor m, Monad m, FormError error, ErrorInputType error ~ input, FormInput input, ToMarkup lbl) =>
              [(a, lbl)]  -- ^ value, label, initially checked
           -> (a -> Bool) -- ^ isDefault
           -> Form m input error Html () a
inputRadio' choices isDefault =
    G.inputChoice isDefault choices mkRadios
    where
      mkRadios nm choices' = mconcat $ concatMap (mkRadio nm) choices'
      mkRadio nm (i, val, lbl, checked) =
          [ ((if checked then (! A.checked "checked") else id) $
             input ! A.type_ "radio" ! A.id (toValue i) ! A.name (toValue nm) ! A.value (toValue val))
          , " ", H.label ! A.for (toValue i) $ toHtml lbl]

mainPage :: Html -> Html -> Html -> Bool -> RoutedNomyxServer Html
mainPage body title header footer = do
   ok $ H.html $ do
      H.head $ do
        H.title title
        H.link ! rel "stylesheet" ! type_ "text/css" ! href "/static/css/nomyx.css"
        H.meta ! A.httpEquiv "Content-Type" ! content "text/html;charset=utf-8"
        H.meta ! A.name "keywords" ! A.content "Nomyx, game, rules, Haskell, auto-reference"
      H.body $ do
        H.div ! A.id "container" $ do
           H.div ! A.id "header" $ header
           body
           when footer $ H.div ! A.id "footer" $ "Copyright Corentin Dupont 2012"
