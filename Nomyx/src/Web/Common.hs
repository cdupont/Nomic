{-# LANGUAGE TemplateHaskell, OverloadedStrings, GADTs, ScopedTypeVariables, DeriveDataTypeable,
             RecordWildCards, TypeFamilies, TypeSynonymInstances#-}

module Web.Common where


import Prelude hiding (div, catch)
import Text.Blaze.Html5 hiding (map, output, base)
import Text.Blaze.Html5.Attributes hiding (dir, id)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Web.Routes.PathInfo
import Web.Routes.RouteT
import Web.Routes.TH (derivePathInfo)
import Control.Monad.State
import Control.Concurrent.STM
import Language.Nomyx
import Happstack.Server
import Types as T
import qualified Data.ByteString.Char8 as C
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Text.Reform.Happstack()
import Text.Reform
import Text.Reform.Blaze.String()
import Text.Reform.Happstack()
import Text.Blaze.Internal
import qualified Text.Reform.Generalized as G
import Data.Text(Text, pack)
import Web.Routes.Happstack()
import Happstack.Auth (UserId(..), getUserId, AuthProfileURL)
import Serialize
import Control.Concurrent
       (putMVar, tryPutMVar, killThread, threadDelay, MVar, ThreadId,
        takeMVar, forkIO, newEmptyMVar)
import qualified Control.Exception as CE (catchJust)
import System.IO.Error (isUserError)
import Data.Time as T (getCurrentTime)
import System.IO (stdout, hSetBuffering)
import GHC.IO.Handle.Types (BufferMode(..))
import Control.Exception (evaluate)

data NomyxError = PlayerNameRequired
                | GameNameRequired
                | UniquePlayerName
                | NomyxCFE (CommonFormError [Input])
                  deriving Show

type NomyxForm a = Form (ServerPartT IO) [Input] NomyxError Html () a

default (Integer, Double, Data.Text.Text)

data LoginName = LoginName { login :: PlayerName}
                             deriving (Show, Eq)


-- | associate a player number with a handle
data PlayerClient = PlayerClient PlayerNumber deriving (Eq, Show)

-- | A structure to hold the active games and players
data Server = Server [PlayerClient] deriving (Eq, Show)


data PlayerCommand =
                     HomePage
                   | U_AuthProfile AuthProfileURL
                   | NewPlayer
                   | MainPage
                   | ViewGame        GameName
                   | JoinGame        GameName
                   | LeaveGame       GameName
                   | DoInputChoice   EventNumber
                   | DoInputString   String
                   | NewRule
                   | NewGame
                   | SubmitNewGame
                   | Upload
                   | PSettings
                   | SubmitPlayerSettings
                   deriving (Show)


type RoutedNomyxServer a = RouteT PlayerCommand (ServerPartT IO) a

$(derivePathInfo ''PlayerCommand)
$(derivePathInfo ''LoginName)

instance PathInfo Bool where
  toPathSegments i = [pack $ show i]
  fromPathSegments = pToken (const "bool") (checkBool . show)
   where checkBool str =
           case reads str of
             [(n,[])] -> Just n
             _ ->        Nothing

modDir :: FilePath
modDir = "modules"

evalCommand :: (TVar Session) -> StateT Session IO a -> RoutedNomyxServer a
evalCommand ts sm = liftIO $ do
   s <- atomically $ readTVar ts
   evalStateT sm s

webCommand :: (TVar Session) -> StateT Session IO () -> RoutedNomyxServer ()
webCommand ts sm = liftIO $ do
   s <- atomically $ readTVar ts
   s' <- execStateT sm s
   atomically $ writeTVar ts s'
   save (_logFilePath $ _mSettings $ _multi $ s') (_multi s') --TODO not really nice to put that here


webCommand' :: (TVar Session) -> StateT Session IO () -> RoutedNomyxServer ()
webCommand' ts sm = liftIO $ do
   s <- atomically $ readTVar ts
   s' <- execStateT sm s
   atomically $ writeTVar ts s'
   save (_logFilePath $ _mSettings $ _multi $ s') (_multi s') --TODO not really nice to put that here


protectedExecCommand :: (TVar Session) -> StateT Session IO a -> IO ()
protectedExecCommand ts ss = do
    mv <- newEmptyMVar
    before <- atomically $ readTVar ts
    id <- forkIO $ CE.catchJust  (\e -> if isUserError e then Just () else Nothing) (execBlocking ss before mv) (\e-> putStrLn $ show e)
    forkIO $ watchDog' 10 id mv
    T.getCurrentTime >>= (\a -> putStrLn $ "before takevar " ++ show a)
    res <- takeMVar mv
    case res of
       Nothing -> (atomically $ writeTVar ts before) >> T.getCurrentTime >>= (\a -> putStrLn $ "writing before" ++ show a)
       Just (_, after) -> (atomically $ writeTVar ts after) >> T.getCurrentTime >>= (\a -> putStrLn $ "writing after " ++ show a)

watchDog' :: Int -> ThreadId -> MVar (Maybe x) -> IO ()
watchDog' t tid mv = do
   threadDelay $ t * 1000000
   killThread tid
   T.getCurrentTime >>= (\a -> putStrLn $ "process timeout " ++ show a)
   tryPutMVar mv Nothing
   return ()

execBlocking :: StateT Session IO a -> Session -> MVar (Maybe (a, Session)) -> IO ()
execBlocking ss s mv = do
   hSetBuffering stdout NoBuffering
   T.getCurrentTime >>= (\a -> putStrLn $ "before runstate " ++ show a)
   res <- runStateT ss s --runStateT (inPlayersGameDo 1 $ liftT $ evalExp (do let (a::Int) = a in outputAll $ show a) 1) m --
   T.getCurrentTime >>= (\a -> putStrLn $ "after runstate " ++ show a)
   res' <- evaluate res
   putMVar mv (Just res')


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

mainPage' :: String -> Html -> Html -> Bool -> RoutedNomyxServer Response
mainPage' title header body footer = do
   html <- mainPage title header body footer
   return $ toResponse html

mainPage :: String -> Html -> Html -> Bool -> RoutedNomyxServer Html
mainPage title header body footer = ok $ appTemplate' title header body footer

appTemplate' ::
       String -- ^ title
    -> Html   -- ^ extra tags to include in \<head\>
    -> Html   -- ^ contents to put inside \<body\>
    -> Bool   -- ^ include footer
    -> Html
appTemplate' title headers body footer = do
   H.head $ do
      H.title (string title)
      H.link ! rel "stylesheet" ! type_ "text/css" ! href "/static/css/nomyx.css"
      H.meta ! A.httpEquiv "Content-Type" ! content "text/html;charset=utf-8"
      H.meta ! A.name "keywords" ! A.content "Nomyx, game, rules, Haskell, auto-reference"
      H.script ! A.type_ "text/JavaScript" ! A.src "/static/nomyx.js" $ ""
   H.body $ do
      H.div ! A.id "container" $ do
         H.div ! A.id "header" $ headers
         body
         when footer $ H.div ! A.id "footer" $ "Copyright Corentin Dupont 2012-2013"

appTemplate ::
    ( Monad m
    )
    => String -- ^ title
    -> Html  -- ^ extra tags to include in \<head\>
    -> Html    -- ^ contents to put inside \<body\>
    -> m Response
appTemplate title headers body = do
   return $ toResponse $ appTemplate' title headers body True

getPlayerNumber :: (TVar Session) -> RoutedNomyxServer PlayerNumber
getPlayerNumber ts = do
   (T.Session _ _ (Profiles acidAuth acidProfile _)) <- liftIO $ readTVarIO ts
   uid <- getUserId acidAuth acidProfile
   case uid of
      Nothing -> error "not logged in."
      (Just (UserId userID)) -> return $ fromInteger userID

fieldRequired :: NomyxError -> String -> Either NomyxError String
fieldRequired a []  = Left a
fieldRequired _ str = Right str

instance FormError NomyxError where
    type ErrorInputType NomyxError = [Input]
    commonFormError = NomyxCFE

instance ToMarkup NomyxError where
    toMarkup PlayerNameRequired = "Player Name is required"
    toMarkup GameNameRequired = "Game Name is required"
    toMarkup UniquePlayerName = "Name already taken"
    toMarkup (NomyxCFE e)    = toHtml $ e

