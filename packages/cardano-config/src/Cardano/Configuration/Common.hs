-- | Types that are common to CLI arguments and the configuration files
module Cardano.Configuration.Common
  ( NodeDatabasePaths (..)
  , parseNodeDatabasePaths
  , parseStartAsNonProducingNode

    -- * File paths
  , filePathCodec
  , filePathFormatMarker

    -- * The gRPC endpoint
  , GrpcEndpoint (..)
  , GrpcTlsFiles (..)
  , defaultGrpcListenAddress
  , grpcEndpointObjectCodec
  ) where

import Autodocodec
import Cardano.Configuration.Basic (optionalFieldWithStrict)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), fromSMaybe)
import Data.Aeson (FromJSON, ToJSON)
import Data.IP (IP)
import Data.Text (Text)
import GHC.Generics
import Network.Socket (PortNumber)
import Options.Applicative
import Text.Read (readMaybe)

--------------------------------------------------------------------------------

-- | A JSON string codec for a filesystem path. It encodes exactly like the
-- plain 'FilePath' codec, but carries a sentinel comment ('filePathFormatMarker')
-- that the schema post-processing (in "Cardano.Configuration.Schema") lifts into
-- a @"format": "path"@ annotation, so tooling and editors can tell the value is
-- a path rather than an arbitrary string.
filePathCodec :: JSONCodec FilePath
filePathCodec = codec @FilePath <?> filePathFormatMarker

-- | The sentinel comment that marks a string as a filesystem path. The schema
-- post-processing recognises it, turns it into @"format": "path"@ and strips it
-- from the description. See 'filePathCodec'.
filePathFormatMarker :: Text
filePathFormatMarker = "format:path"

--------------------------------------------------------------------------------

-- | The databases that will be used by the node
data NodeDatabasePaths
  = -- | Store everything in a single directory
    SingleDB FilePath
  | -- | Store the immutable data in one (possibly slower) directory and the
    -- volatile data in a different (possible faster) directory
    SplitDB FilePath FilePath
  deriving (Generic, Show)

-- | A single database is a JSON string (a path); a split database is a JSON
-- object. We dispatch on that shape so a malformed split-database object reports
-- its own failure rather than alongside the irrelevant "expected String" failure
-- of the single-path branch.
instance HasCodec NodeDatabasePaths where
  codec =
    matchChoiceCodec
      (dimapCodec SingleDB id filePathCodec)
      (dimapCodec (uncurry SplitDB) id splitDbCodec)
      selector
   where
    splitDbCodec =
      object "SplitDB" $
        (,)
          <$> requiredFieldWith "ImmutablePath" filePathCodec "Directory for the immutable database" .= fst
          <*> requiredFieldWith "VolatilePath" filePathCodec "Directory for the volatile database" .= snd
    selector (SingleDB fp) = Left fp
    selector (SplitDB i v) = Right (i, v)

deriving via (Autodocodec NodeDatabasePaths) instance FromJSON NodeDatabasePaths

deriving via (Autodocodec NodeDatabasePaths) instance ToJSON NodeDatabasePaths

parseNodeDatabasePaths :: Parser (Maybe NodeDatabasePaths)
parseNodeDatabasePaths =
  optional $ parseMultipleDbPaths <|> parseDbPath

parseDbPath :: Parser NodeDatabasePaths
parseDbPath =
  fmap SingleDB $
    strOption $
      mconcat
        [ long "database-path"
        , metavar "FILEPATH"
        , help "Directory where the state is stored"
        , completer (bashCompleter "file")
        ]

parseMultipleDbPaths :: Parser NodeDatabasePaths
parseMultipleDbPaths = SplitDB <$> parseImmutableDbPath <*> parseVolatileDbPath

parseVolatileDbPath :: Parser FilePath
parseVolatileDbPath =
  strOption $
    mconcat
      [ long "volatile-database-path"
      , metavar "FILEPATH"
      , help "Directory where the volatile state is stored"
      , completer (bashCompleter "file")
      ]

parseImmutableDbPath :: Parser FilePath
parseImmutableDbPath =
  strOption $
    mconcat
      [ long "immutable-database-path"
      , metavar "FILEPATH"
      , help "Directory where the immutable state is stored"
      , completer (bashCompleter "file")
      ]

-- | The value missing means "unset" not @False@, hence the @Maybe Bool@.
parseStartAsNonProducingNode :: Parser (Maybe Bool)
parseStartAsNonProducingNode =
  flag Nothing (Just True) $
    mconcat
      [ long "start-as-non-producing-node"
      , help $
          mconcat
            [ "Start the node as a non block-producing node even if "
            , "credentials are specified"
            ]
      ]

--------------------------------------------------------------------------------

-- | Where the node's gRPC server listens: a local unix socket (the default),
-- plaintext HTTP\/2 (@h2c@) on a TCP port, or HTTP\/2 over TLS on a TCP port.
-- Exactly one listener is active, so the three forms are alternatives rather
-- than a record of independent settings. Mirrors @cardano-rpc@'s @RpcEndpoint@.
--
-- In the configuration file it is written flat, as the @Grpc*@ keys of
-- @LocalConnections@ (see 'grpcEndpointObjectCodec'). It stays optional
-- in a resolved configuration, because the consumer derives the default socket
-- (@rpc.sock@ beside the node socket), a path @defaults\/@ cannot name.
data GrpcEndpoint
  = -- | A unix socket at this path.
    GrpcEndpointUnixSocket FilePath
  | -- | The address and port of the HTTP\/2 without TLS (h2c) listener.
    GrpcEndpointHttp IP PortNumber
  | -- | The address, port and TLS credential files of the HTTP\/2 over TLS
    --     listener.
    GrpcEndpointHttps IP PortNumber GrpcTlsFiles
  deriving (Eq, Show, Generic)

-- | The TLS credential files of the gRPC server, in PEM format. The certificate
-- and the private key go together; the chain is optional.
data GrpcTlsFiles = GrpcTlsFiles
  { certificateFile :: FilePath
  -- ^ The server's X.509 certificate.
  , privateKeyFile :: FilePath
  -- ^ The private key matching that certificate.
  , chainCertificateFiles :: [FilePath]
  -- ^ The intermediate chain certificates, if any.
  }
  deriving (Eq, Show, Generic)

-- | The address the gRPC listener binds to when a port is configured without
-- one. Loopback, so a plaintext endpoint is not exposed off-host by accident.
defaultGrpcListenAddress :: IP
defaultGrpcListenAddress = "127.0.0.1"

-- | The gRPC endpoint as a configuration file writes it: a flat group of
-- optional keys inside @LocalConnections@, folded into the 'GrpcEndpoint'
-- they describe, and unfolded again when rendering.
--
-- The combinations that describe no single listener are rejected here, at parse
-- time: a socket path excludes the TCP keys, an address or a TLS credential
-- needs a port, and the certificate and private key go together. Mirrors
-- @cardano-node@'s @parsePartialRpcConfig@.
--
-- Being a 'bimapCodec' it is transparent to schema generation, so the schema
-- documents the flat keys.
grpcEndpointObjectCodec :: JSONObjectCodec (StrictMaybe GrpcEndpoint)
grpcEndpointObjectCodec = bimapCodec toEndpoint fromEndpoint grpcEndpointFieldsCodec

-- | The flat keys 'grpcEndpointObjectCodec' reads, before they are folded into
-- a 'GrpcEndpoint'.
data GrpcEndpointFields = GrpcEndpointFields
  { fSocketPath :: StrictMaybe FilePath
  , fListenAddress :: StrictMaybe IP
  , fListenPort :: StrictMaybe PortNumber
  , fTlsCertificateFile :: StrictMaybe FilePath
  , fTlsPrivateKeyFile :: StrictMaybe FilePath
  , fTlsChainCertificateFiles :: StrictMaybe [FilePath]
  }

grpcEndpointFieldsCodec :: JSONObjectCodec GrpcEndpointFields
grpcEndpointFieldsCodec =
  GrpcEndpointFields
    <$> optionalFieldWithStrict
      "GrpcSocketPath"
      filePathCodec
      "Path of the gRPC server socket. Mutually exclusive with GrpcListenPort"
      .= fSocketPath
    <*> optionalFieldWithStrict
      "GrpcListenAddress"
      ipCodec
      "IP address (IPv4 or IPv6) the gRPC server binds to. Requires GrpcListenPort. Defaults to 127.0.0.1"
      .= fListenAddress
    <*> optionalFieldWithStrict
      "GrpcListenPort"
      portNumberCodec
      ( "TCP port the gRPC server listens on. When set, the gRPC server listens over HTTP/2 rather "
          <> "than on a unix socket, without TLS unless GrpcTlsCertificateFile is also given. "
          <> "Mutually exclusive with GrpcSocketPath"
      )
      .= fListenPort
    <*> optionalFieldWithStrict
      "GrpcTlsCertificateFile"
      filePathCodec
      "Path of the gRPC server's TLS certificate (PEM). Enables TLS; requires GrpcTlsPrivateKeyFile and GrpcListenPort"
      .= fTlsCertificateFile
    <*> optionalFieldWithStrict
      "GrpcTlsPrivateKeyFile"
      filePathCodec
      ( "Path of the private key matching GrpcTlsCertificateFile (PEM). Requires "
          <> "GrpcTlsCertificateFile and GrpcListenPort"
      )
      .= fTlsPrivateKeyFile
    <*> optionalFieldWithStrict
      "GrpcTlsChainCertificateFiles"
      (listCodec filePathCodec)
      "Paths of the intermediate certificates to include in the gRPC server's TLS chain (PEM)"
      .= fTlsChainCertificateFiles

-- | Fold the flat keys into the endpoint they describe, rejecting the
-- combinations that describe none.
toEndpoint :: GrpcEndpointFields -> Either String (StrictMaybe GrpcEndpoint)
toEndpoint fields = do
  tls <- toTlsFiles fields
  case (fSocketPath fields, fListenAddress fields, fListenPort fields, tls) of
    (SJust _, SJust _, _, _) ->
      Left "GrpcSocketPath and GrpcListenAddress are mutually exclusive"
    (SJust _, _, SJust _, _) ->
      Left "GrpcSocketPath and GrpcListenPort are mutually exclusive"
    (SJust _, _, _, Just _) ->
      Left "GrpcSocketPath and the GrpcTls* keys are mutually exclusive"
    (SJust path, SNothing, SNothing, Nothing) ->
      Right (SJust (GrpcEndpointUnixSocket path))
    (SNothing, SJust _, SNothing, _) ->
      Left "GrpcListenAddress requires GrpcListenPort to be set"
    (SNothing, _, SNothing, Just _) ->
      Left "the GrpcTls* keys require GrpcListenPort to be set"
    (SNothing, _, SJust port, Just tlsFiles) ->
      Right (SJust (GrpcEndpointHttps (listenAddress fields) port tlsFiles))
    (SNothing, _, SJust port, Nothing) ->
      Right (SJust (GrpcEndpointHttp (listenAddress fields) port))
    (SNothing, SNothing, SNothing, Nothing) ->
      Right SNothing
 where
  listenAddress = fromSMaybe defaultGrpcListenAddress . fListenAddress

-- | The TLS credentials of the flat keys. The certificate and the private key
-- are given together or not at all, and a chain without them is an error.
toTlsFiles :: GrpcEndpointFields -> Either String (Maybe GrpcTlsFiles)
toTlsFiles fields =
  case (fTlsCertificateFile fields, fTlsPrivateKeyFile fields) of
    (SJust certificateFile, SJust privateKeyFile) ->
      Right . Just $
        GrpcTlsFiles
          { certificateFile
          , privateKeyFile
          , chainCertificateFiles = fromSMaybe [] (fTlsChainCertificateFiles fields)
          }
    (SNothing, SNothing)
      | SJust _ <- fTlsChainCertificateFiles fields ->
          Left
            "GrpcTlsChainCertificateFiles requires GrpcTlsCertificateFile and GrpcTlsPrivateKeyFile to be set"
      | otherwise -> Right Nothing
    _ -> Left "GrpcTlsCertificateFile and GrpcTlsPrivateKeyFile must be set together"

-- | Unfold an endpoint back into the flat keys. An empty TLS chain is written as
-- no key at all, so that decoding the result gives the endpoint back unchanged.
fromEndpoint :: StrictMaybe GrpcEndpoint -> GrpcEndpointFields
fromEndpoint endpoint =
  case endpoint of
    SNothing -> noFields
    SJust (GrpcEndpointUnixSocket path) -> noFields{fSocketPath = SJust path}
    SJust (GrpcEndpointHttp address port) -> listener address port
    SJust (GrpcEndpointHttps address port tlsFiles) ->
      (listener address port)
        { fTlsCertificateFile = SJust (certificateFile tlsFiles)
        , fTlsPrivateKeyFile = SJust (privateKeyFile tlsFiles)
        , fTlsChainCertificateFiles = case chainCertificateFiles tlsFiles of
            [] -> SNothing
            chain -> SJust chain
        }
 where
  noFields = GrpcEndpointFields SNothing SNothing SNothing SNothing SNothing SNothing
  listener address port = noFields{fListenAddress = SJust address, fListenPort = SJust port}

-- | A JSON string codec for an IP address, in the textual forms @Data.IP@
-- reads and shows.
ipCodec :: JSONCodec IP
ipCodec = bimapCodec parse show (codec @String)
 where
  parse s = maybe (Left ("failed to parse the IP address " <> show s)) Right (readMaybe s)

-- | A JSON number codec for a TCP port, rejecting values outside 0 - 65535
-- rather than silently wrapping them.
portNumberCodec :: JSONCodec PortNumber
portNumberCodec = boundedIntegralCodec
