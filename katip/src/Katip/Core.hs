{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}

module Katip.Core where

-------------------------------------------------------------------------------
import           Control.Applicative
import           Control.AutoUpdate
import           Control.Concurrent
import           Control.Lens
import           Control.Monad.Catch
import           Control.Monad.Reader
import           Data.Aeson                 (ToJSON (..))
import qualified Data.Aeson                 as A
import           Data.Aeson.Lens
import qualified Data.HashMap.Strict        as HM
import           Data.List
import qualified Data.Map.Strict            as M
import           Data.Monoid
import           Data.String
import           Data.String.Conv
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Lazy.Builder     as B
import           Data.Time
import           GHC.Generics               hiding (to)
import           Language.Haskell.TH
import qualified Language.Haskell.TH.Syntax as TH
import           Network.HostName
import           System.Posix
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
newtype Namespace = Namespace { getNamespace :: [Text] }
  deriving (Eq,Show,Read,Ord,Generic,ToJSON,Monoid)

instance IsString Namespace where
    fromString s = Namespace [fromString s]


-------------------------------------------------------------------------------
-- | Ready namespace for emission with dots to join the segments.
intercalateNs :: Namespace -> [Text]
intercalateNs (Namespace xs) = intersperse "." xs


-------------------------------------------------------------------------------
-- | Application environment, like @prod@, @devel@, @testing@.
newtype Environment = Environment { getEnvironment :: Text }
  deriving (Eq,Show,Read,Ord,Generic,ToJSON,IsString)


-------------------------------------------------------------------------------
data Severity
    = Debug                   -- ^ Debug messages
    | Info                    -- ^ Information
    | Notice                  -- ^ Normal runtime Conditions
    | Warning                 -- ^ General Warnings
    | Error                   -- ^ General Errors
    | Critical                -- ^ Severe situations
    | Alert                   -- ^ Take immediate action
    | Emergency               -- ^ System is unusable
  deriving (Eq, Ord, Show, Read, Generic)


-------------------------------------------------------------------------------
-- | Verbosity controls the amount of information (columns) a 'Scribe'
-- emits during logging.
--
-- The convention is:
-- - 'V0' implies no additional payload information is included in message.
-- - 'V3' implies the maximum amount of payload information.
-- - Anything in between is left to the discretion of the developer.
data Verbosity = V0 | V1 | V2 | V3
  deriving (Eq, Ord, Show, Read, Generic)


-------------------------------------------------------------------------------
renderSeverity :: Severity -> Text
renderSeverity s = case s of
      Debug -> "Debug"
      Info -> "Info"
      Notice -> "Notice"
      Warning -> "Warning"
      Error -> "Error"
      Critical -> "Critical"
      Alert -> "Alert"
      Emergency -> "Emergency"


-------------------------------------------------------------------------------
instance ToJSON Severity where
    toJSON s = A.String (renderSeverity s)


-------------------------------------------------------------------------------
-- | Log message with Builder unerneath; use '<>' to concat in O(1).
newtype LogStr = LogStr { unLogStr :: B.Builder }
    deriving (Generic)

instance IsString LogStr where
    fromString = LogStr . B.fromString


-------------------------------------------------------------------------------
-- | Pack any string-like thing into a 'LogMsg'. This will
-- automatically work on 'String', 'ByteString, 'Text' and any of the
-- lazy variants.
logStr :: StringConv a Text => a -> LogStr
logStr t = LogStr (B.fromText $ toS t)


-------------------------------------------------------------------------------
-- | Shorthand for 'logMsg'
ls :: StringConv a Text => a -> LogStr
ls = logStr


-------------------------------------------------------------------------------
-- | This has everything each log message will contain.
data Item a = Item {
      itemApp       :: Namespace
    , itemEnv       :: Environment
    , itemSeverity  :: Severity
    , itemThread    :: ThreadId
    , itemHost      :: HostName
    , itemProcess   :: ProcessID
    , itemPayload   :: a
    , itemMessage   :: LogStr
    , itemTime      :: UTCTime
    , itemNamespace :: Namespace
    , itemLoc       :: Maybe Loc
    } deriving (Generic)



instance ToJSON a => ToJSON (Item a) where
    toJSON Item{..} = A.object
      [ "app" A..= itemApp
      , "env" A..= itemEnv
      , "sev" A..= itemSeverity
      , "thread" A..= show itemThread
      , "host" A..= itemHost
      , "pid" A..= A.String (toS (show itemProcess))
      , "data" A..= itemPayload
      , "msg" A..= (B.toLazyText $ unLogStr itemMessage)
      , "at" A..= itemTime
      , "ns" A..= itemNamespace
      , "loc" A..= fmap LocJs itemLoc
      ]

newtype LocJs = LocJs { getLocJs :: Loc }


instance ToJSON LocJs where
    toJSON (LocJs (Loc fn p m (l, c) _)) = A.object
      [ "loc_fn" A..= fn
      , "loc_pkg" A..= p
      , "loc_mod" A..= m
      , "loc_ln" A..= l
      , "loc_col" A..= c
      ]


-------------------------------------------------------------------------------
-- | Field selector by verbosity within JSON payload.
data PayloadSelection
    = AllKeys
    | SomeKeys [Text]

-------------------------------------------------------------------------------
-- | Payload objects need instances of this class.
class ToJSON a => LogContext a where

    -- | List of keys in the JSON object that should be included in message.
    payloadKeys :: Verbosity -> a -> PayloadSelection


instance LogContext () where payloadKeys _ _ = SomeKeys []


-------------------------------------------------------------------------------
-- | Constrain payload based on verbosity. To be used by backends.
payloadJson :: LogContext a => Verbosity -> a -> A.Value
payloadJson verb a = case payloadKeys verb a of
    AllKeys -> toJSON a
    SomeKeys ks -> toJSON a
      & _Object %~ HM.filterWithKey (\ k _ -> k `elem` ks)


-------------------------------------------------------------------------------
-- | Scribes are handlers of incoming items. Each registered scribe
-- knows how to push a log item somewhere.
data Scribe = Scribe {
      lhPush :: forall a. LogContext a => Item a -> IO ()
    }


instance Monoid Scribe where
    mempty = Scribe $ const $ return ()
    mappend (Scribe a) (Scribe b) = Scribe $ \ item -> do
      a item
      b item

-------------------------------------------------------------------------------
data LogEnv = LogEnv {
      _logEnvHost    :: HostName
    , _logEnvPid     :: ProcessID
    , _logEnvNs      :: Namespace
    , _logEnvEnv     :: Environment
    , _logEnvTimer   :: IO UTCTime
    , _logEnvScribes :: M.Map Text Scribe
    }
makeLenses ''LogEnv


-------------------------------------------------------------------------------
initLogEnv
    :: Namespace
    -- ^ A base namespace for this application
    -> Environment
    -- ^ Current run environment (e.g. @prod@ vs. @devel@)
    -> IO LogEnv
initLogEnv an env = LogEnv
  <$> getHostName
  <*> getProcessID
  <*> pure an
  <*> pure env
  <*> mkAutoUpdate defaultUpdateSettings { updateAction = getCurrentTime }
  <*> pure mempty


-------------------------------------------------------------------------------
registerScribe
    :: Text
    -- ^ Name the scribe
    -> Scribe
    -> LogEnv
    -> LogEnv
registerScribe nm h = logEnvScribes . at nm .~ Just h


-------------------------------------------------------------------------------
unregisterScribe
    :: Text
    -- ^ Name of the scribe
    -> LogEnv
    -> LogEnv
unregisterScribe nm = logEnvScribes . at nm .~ Nothing



class Katip m where
    getLogEnv :: m LogEnv


-------------------------------------------------------------------------------
-- | A concrete monad you can use to run logging actions.
newtype KatipT m a = KatipT { unKatipT :: ReaderT LogEnv m a }
  deriving ( Monad, MonadIO, MonadMask, MonadCatch, MonadThrow
           , MonadReader LogEnv)


-------------------------------------------------------------------------------
-- | Execute 'KatipT' on a log env.
runKatipT :: LogEnv -> KatipT m a -> m a
runKatipT le (KatipT f) = runReaderT f le


-------------------------------------------------------------------------------
-- | Log with everything, including a source code location. This is
-- very low level and you typically can use 'logT' in its place.
logI
    :: (Applicative m, MonadIO m, LogContext a, Katip m)
    => a
    -> Namespace
    -> Maybe Loc
    -> Severity
    -> LogStr
    -> m ()
logI a ns loc sev msg = do
    LogEnv{..} <- getLogEnv
    item <- Item
      <$> pure _logEnvNs
      <*> pure _logEnvEnv
      <*> pure sev
      <*> liftIO myThreadId
      <*> pure _logEnvHost
      <*> pure _logEnvPid
      <*> pure a
      <*> pure msg
      <*> liftIO _logEnvTimer
      <*> pure (_logEnvNs <> ns)
      <*> pure loc
    liftIO $ forM_ (M.elems _logEnvScribes) $ \ (Scribe h) -> h item


-------------------------------------------------------------------------------
-- | Log with full context, but without any code location.
logF
  :: (Applicative m, MonadIO m, LogContext a, Katip m)
  => a
  -- ^ Contextual payload for the log
  -> Namespace
  -- ^ Specific namespace of the message.
  -> Severity
  -- ^ Severity of the message
  -> LogStr
  -- ^ The log message
  -> m ()
logF a ns sev msg = logI a ns Nothing sev msg


-------------------------------------------------------------------------------
-- | Log a message without any payload/context or code location.
logM
    :: (Applicative m, MonadIO m, Katip m)
    => Namespace
    -> Severity
    -> LogStr
    -> m ()
logM ns sev msg = logF () ns sev msg


instance TH.Lift Namespace where
    lift (Namespace xs) =
      let xs' = map T.unpack xs
      in  [| Namespace (map T.pack xs') |]


instance TH.Lift Verbosity where
    lift V0 = [| V0 |]
    lift V1 = [| V1 |]
    lift V2 = [| V2 |]
    lift V3 = [| V3 |]


instance TH.Lift Severity where
    lift Debug = [| Debug |]
    lift Info  = [| Info |]
    lift Notice  = [| Notice |]
    lift Warning  = [| Warning |]
    lift Error  = [| Error |]
    lift Critical  = [| Critical |]
    lift Alert  = [| Alert |]
    lift Emergency  = [| Emergency |]


-- | Lift a location into an Exp.
liftLoc :: Loc -> Q Exp
liftLoc (Loc a b c (d1, d2) (e1, e2)) = [|Loc
    $(TH.lift a)
    $(TH.lift b)
    $(TH.lift c)
    ($(TH.lift d1), $(TH.lift d2))
    ($(TH.lift e1), $(TH.lift e2))
    |]


-------------------------------------------------------------------------------
-- | For use when you want to include location in your logs. This will
-- fill the 'Maybe Loc' gap in 'logF' of this module.
getLoc :: Q Exp
getLoc = [| $(location >>= liftLoc) |]


-------------------------------------------------------------------------------
-- | 'Loc'-tagged logging when using template-haskell is OK.
--
-- @$(logT) obj mempty Info "Hello world"@
logT :: ExpQ
logT = [| \ a ns sev msg -> logI a ns (Just $(getLoc)) sev msg |]


-- taken from the file-location package
-- turn the TH Loc loaction information into a human readable string
-- leaving out the loc_end parameter
locationToString :: Loc -> String
locationToString loc = (loc_package loc) ++ ':' : (loc_module loc) ++
  ' ' : (loc_filename loc) ++ ':' : (line loc) ++ ':' : (char loc)
  where
    line = show . fst . loc_start
    char = show . snd . loc_start
