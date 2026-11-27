module Cardano.Configuration.CliArgs
  ( -- * CLI Arguments
    CliArgs (..)
  , parseCliArgs
  , defaultCliArgs
  , ShutdownOn (..)

    -- * Tracing
  , TracerConnectionMethod (..)
  , TracerConnection (..)

    -- * The gRPC endpoint

  -- Re-exported so that a consumer building a 'CliArgs' directly can name the
  -- type of 'grpcEndpointCLI'.
  , GrpcEndpoint (..)
  , GrpcTlsFiles (..)
  , defaultGrpcListenAddress

    -- * The database paths

  -- Re-exported for the same reason, for 'databasePathCLI'.
  , NodeDatabasePaths (..)

    -- * Credentials
  , Credentials (..)
  , emptyCredentials
  , KESSource (..)

    -- * Individual option parsers

  -- These are exported so that other tools (e.g. @cardano-cli@) can reuse the
  -- exact same flags, metavars and help text as @cardano-node@.
  , parseConfigFile
  , parseTopologyFile
  , parseSocketPath
  , parseValidateDB
  , parseNodeDatabasePaths
  , parseStartAsNonProducingNode
  , parseEnableGrpc
  , parseGrpcEndpoint
  , parseGrpcSocketPath
  , parseGrpcListenAddress
  , parseGrpcListenPort
  , parseGrpcTlsFiles
  , parseCredentials
  , parseKESSource
  , parseHostIPv4Addr
  , parseHostIPv6Addr
  , parsePort
  , parseTracerSocketMode
  , parseShutdownIPC
  , parseShutdownOn

    -- ** Argument readers
  , parseNodeAddress
  , parseHostPort
  , parseNodeHostIPAddress
  , parseNodeHostIPv4Address
  , parseNodeHostIPv6Address
  ) where

import Cardano.Configuration.Common
import Cardano.Ledger.BaseTypes (StrictMaybe (..), maybeToStrictMaybe)
import Control.Monad (unless, when)
import Data.Bifunctor (second)
import Data.Char (isDigit)
import Data.IP (IP, IPv4, IPv6)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Network.Socket (PortNumber)
import Network.URI (URI (..), URIAuth (..), parseURIReference)
import Options.Applicative
import System.Posix.Types (Fd (..))
import Text.Read (readEither, readMaybe)

-- | A condition under which the node shuts itself down once the chain database
-- has synced up to the given point: a slot (@--shutdown-on-slot-synced@) or a
-- block number (@--shutdown-on-block-synced@).
data ShutdownOn
  = ShutdownAtSlot Word64
  | ShutdownAtBlock Word64
  deriving Show

type Host = Text

-- | How the node reaches @cardano-tracer@: over a local socket\/named pipe
-- ('TracerConnectViaPipe') or a network address ('TracerConnectViaRemote').
data TracerConnectionMethod
  = TracerConnectViaPipe FilePath
  | TracerConnectViaRemote Host PortNumber
  deriving Show

-- | A tracer connection: the socket mode (@"Accept"@ to accept an incoming
-- @cardano-tracer@ connection, @"Connect"@ to dial out to a listening one)
-- paired with the 'TracerConnectionMethod' to use.
data TracerConnection
  = TracerConnection String TracerConnectionMethod
  deriving Show

-- | Where the Shelley KES signing key comes from: a key file on disk
-- ('KESKeyFilePath') or a running KES agent's socket ('KESAgentSocketPath').
data KESSource
  = KESKeyFilePath FilePath
  | KESAgentSocketPath FilePath
  deriving (Eq, Show)

-- | The block-forging credentials supplied on the command line: the Byron
-- delegation certificate and signing key, the Shelley KES\/VRF keys and
-- operational certificate, the BLS (Leios) signing key, or a single bulk
-- credentials file. All are optional;
-- their presence is what makes the node a block producer (see
-- @roleFromCredentials@).
data Credentials = Credentials
  { byronDelegationCertificate :: StrictMaybe FilePath
  , byronSigningKey :: StrictMaybe FilePath
  , shelleyKES :: StrictMaybe KESSource
  , shelleyVRFKey :: StrictMaybe FilePath
  , shelleyOperationalCertificate :: StrictMaybe FilePath
  , shelleyBLSKey :: StrictMaybe FilePath
  , bulkCredentialsFile :: StrictMaybe FilePath
  }
  deriving Show

-- | The block-forging credentials with nothing supplied: the value
-- 'parseCredentials' yields when no credential flag is given. A node with these
-- credentials is not a block producer.
emptyCredentials :: Credentials
emptyCredentials =
  Credentials
    { byronDelegationCertificate = SNothing
    , byronSigningKey = SNothing
    , shelleyKES = SNothing
    , shelleyVRFKey = SNothing
    , shelleyOperationalCertificate = SNothing
    , shelleyBLSKey = SNothing
    , bulkCredentialsFile = SNothing
    }

-- | The CLI arguments, parsed with 'parseCliArgs'
data CliArgs = CliArgs
  { configFilePath :: FilePath
  , topologyFile :: FilePath
  , databasePathCLI :: StrictMaybe NodeDatabasePaths
  , validateDatabase :: Bool
  , socketPath :: StrictMaybe FilePath
  , credentials :: Credentials
  , startAsNonProducingNode :: StrictMaybe Bool
  , hostAddr :: StrictMaybe IPv4
  , hostIPv6Addr :: StrictMaybe IPv6
  , port :: StrictMaybe PortNumber
  , tracerSocket :: StrictMaybe TracerConnection
  , shutdownIPC :: StrictMaybe Fd
  , shutdownOnTarget :: StrictMaybe ShutdownOn
  , enableGrpcCLI :: StrictMaybe Bool
  , grpcEndpointCLI :: StrictMaybe GrpcEndpoint
  }
  deriving Show

parseCredentials :: Parser Credentials
parseCredentials =
  Credentials
    <$> optionalStrict parseByronDelegationCert
    <*> optionalStrict parseByronSigningKey
    <*> optionalStrict parseKESSource
    <*> optionalStrict parseVrfKeyFilePath
    <*> optionalStrict parseOperationalCertFilePath
    <*> optionalStrict parseBlsKeyFilePath
    <*> optionalStrict parseBulkCredsFilePath

-- | Like optparse-applicative's 'optional', but yielding a 'StrictMaybe' to
-- match the strict CLI-argument fields (see the package's @StrictData@ usage).
optionalStrict :: Alternative f => f a -> f (StrictMaybe a)
optionalStrict = fmap maybeToStrictMaybe . optional

parseCliArgs :: Parser CliArgs
parseCliArgs =
  CliArgs
    <$> parseConfigFile
    <*> parseTopologyFile
    <*> parserOptionGroup "Storage:" (maybeToStrictMaybe <$> parseNodeDatabasePaths)
    <*> parserOptionGroup "Storage:" parseValidateDB
    <*> optionalStrict parseSocketPath
    <*> parserOptionGroup "Credentials:" parseCredentials
    <*> parserOptionGroup "Credentials:" (maybeToStrictMaybe <$> parseStartAsNonProducingNode)
    <*> parserOptionGroup "Host:" (optionalStrict parseHostIPv4Addr)
    <*> parserOptionGroup "Host:" (optionalStrict parseHostIPv6Addr)
    <*> parserOptionGroup "Host:" (optionalStrict parsePort)
    <*> parserOptionGroup "Tracing:" (optionalStrict parseTracerSocketMode)
    <*> parserOptionGroup "Shutdown:" (optionalStrict parseShutdownIPC)
    <*> parserOptionGroup "Shutdown:" (optionalStrict parseShutdownOn)
    <*> optionalStrict parseEnableGrpc
    <*> optionalStrict parseGrpcEndpoint

-- | The 'CliArgs' for resolving a configuration from its file alone, with no
-- command-line overrides: every field takes the value 'parseCliArgs' would
-- produce were the command line to carry nothing but @--config CONFIGFILE@.
-- Intended for tools that consume a node configuration file but expose no node
-- command line of their own (see
-- 'Cardano.Configuration.resolveConfigurationFromFile'). Consumers that do need
-- to override some fields can start from this value and update the ones they
-- care about, rather than spelling out every default.
defaultCliArgs :: FilePath -> CliArgs
defaultCliArgs configFile =
  CliArgs
    { configFilePath = configFile
    , topologyFile = defaultTopologyFile
    , databasePathCLI = SNothing
    , validateDatabase = False
    , socketPath = SNothing
    , credentials = emptyCredentials
    , startAsNonProducingNode = SNothing
    , hostAddr = SNothing
    , hostIPv6Addr = SNothing
    , port = SNothing
    , tracerSocket = SNothing
    , shutdownIPC = SNothing
    , shutdownOnTarget = SNothing
    , enableGrpcCLI = SNothing
    , grpcEndpointCLI = SNothing
    }

-- | The topology file path used when @--topology@ is not given.
defaultTopologyFile :: FilePath
defaultTopologyFile = "configuration/cardano/mainnet-topology.json"

parseTopologyFile :: Parser FilePath
parseTopologyFile =
  strOption $
    mconcat
      [ long "topology"
      , metavar "FILEPATH"
      , help "The path to a file describing the topology"
      , completer (bashCompleter "file")
      , value defaultTopologyFile
      , showDefault
      ]

parseValidateDB :: Parser Bool
parseValidateDB =
  switch $
    mconcat
      [ long "validate-db"
      , help "Validate all on-disk database files"
      ]

parseSocketPath :: Parser FilePath
parseSocketPath =
  strOption $
    mconcat
      [ long "socket-path"
      , help "Path to create a socket for local clients"
      , metavar "FILEPATH"
      , completer (bashCompleter "file")
      ]

parseEnableGrpc :: Parser Bool
parseEnableGrpc =
  flag' True $
    mconcat
      [ long "grpc-enable"
      , help "[EXPERIMENTAL] Enable node gRPC endpoint."
      ]

-- | Where the gRPC server listens: @--grpc-socket-path@ for a unix socket, or
-- @--grpc-listen-port@ for a TCP listener, with an optional
-- @--grpc-listen-address@ and the @--grpc-tls-*@ credentials for TLS. The two
-- forms are mutually exclusive, and with neither the endpoint is unset.
parseGrpcEndpoint :: Parser GrpcEndpoint
parseGrpcEndpoint = parseGrpcUnixSocketEndpoint <|> parseGrpcHttpEndpoint
 where
  parseGrpcUnixSocketEndpoint = GrpcEndpointUnixSocket <$> parseGrpcSocketPath
  -- The TLS credentials decide between the plaintext (h2c) and the TLS
  -- listener. The address defaults to loopback.
  parseGrpcHttpEndpoint =
    mkHttpEndpoint
      <$> optional parseGrpcListenAddress
      <*> parseGrpcListenPort
      <*> optional parseGrpcTlsFiles
  mkHttpEndpoint mAddress port =
    maybe (GrpcEndpointHttp address port) (GrpcEndpointHttps address port)
   where
    address = fromMaybe defaultGrpcListenAddress mAddress

parseGrpcSocketPath :: Parser FilePath
parseGrpcSocketPath =
  strOption $
    mconcat
      [ long "grpc-socket-path"
      , metavar "FILEPATH"
      , help $
          mconcat
            [ "[EXPERIMENTAL] gRPC unix socket path. Defaults to rpc.sock in the same directory as "
            , "node socket. Mutually exclusive with --grpc-listen-port."
            ]
      , completer (bashCompleter "file")
      ]

parseGrpcListenPort :: Parser PortNumber
parseGrpcListenPort =
  option (bounded "PORT") $
    mconcat
      [ long "grpc-listen-port"
      , metavar "PORT"
      , help $
          mconcat
            [ "[EXPERIMENTAL] TCP port the gRPC server listens on. When set, the gRPC server listens "
            , "over HTTP/2 without TLS, or HTTP/2 over TLS if --grpc-tls-certificate is given, "
            , "instead of a unix socket. Mutually exclusive with --grpc-socket-path."
            ]
      ]

parseGrpcListenAddress :: Parser IP
parseGrpcListenAddress =
  option (eitherReader parseNodeHostIPAddress) $
    mconcat
      [ long "grpc-listen-address"
      , metavar "IP-ADDRESS"
      , help $
          mconcat
            [ "[EXPERIMENTAL] IP address the gRPC server binds to. Requires --grpc-listen-port. "
            , "Defaults to 127.0.0.1."
            ]
      ]

-- | The gRPC server's TLS credentials. The certificate and the private key are
-- required together, so giving either alone fails the parse. The chain
-- certificates are optional and repeatable.
parseGrpcTlsFiles :: Parser GrpcTlsFiles
parseGrpcTlsFiles =
  GrpcTlsFiles
    <$> parseGrpcTlsCertificateFile
    <*> parseGrpcTlsPrivateKeyFile
    <*> many parseGrpcTlsChainCertificateFile
 where
  parseGrpcTlsCertificateFile =
    strOption $
      mconcat
        [ long "grpc-tls-certificate"
        , metavar "FILEPATH"
        , help $
            mconcat
              [ "[EXPERIMENTAL] Path to the TLS certificate file. Enables TLS; requires "
              , "--grpc-tls-private-key and --grpc-listen-port."
              ]
        , completer (bashCompleter "file")
        ]
  parseGrpcTlsPrivateKeyFile =
    strOption $
      mconcat
        [ long "grpc-tls-private-key"
        , metavar "FILEPATH"
        , help $
            mconcat
              [ "[EXPERIMENTAL] Path to the TLS private key file. Requires --grpc-tls-certificate "
              , "and --grpc-listen-port."
              ]
        , completer (bashCompleter "file")
        ]
  parseGrpcTlsChainCertificateFile =
    strOption $
      mconcat
        [ long "grpc-tls-chain-certificate"
        , metavar "FILEPATH"
        , help $
            mconcat
              [ "[EXPERIMENTAL] Path to an additional certificate to include in the TLS chain. May "
              , "be given multiple times. Requires --grpc-tls-certificate and --grpc-tls-private-key."
              ]
        , completer (bashCompleter "file")
        ]

parseConfigFile :: Parser FilePath
parseConfigFile =
  strOption $
    mconcat
      [ long "config"
      , metavar "FILEPATH"
      , help "Configuration file for the cardano-node"
      , completer (bashCompleter "file")
      , value "configuration/cardano/mainnet-config.json"
      , showDefault
      ]

parseHostIPv4Addr :: Parser IPv4
parseHostIPv4Addr =
  option
    (eitherReader parseNodeHostIPv4Address)
    $ mconcat
      [ long "host-addr"
      , metavar "IPV4"
      , help "An optional IPv4 address"
      ]

parseHostIPv6Addr :: Parser IPv6
parseHostIPv6Addr =
  option
    (eitherReader parseNodeHostIPv6Address)
    $ mconcat
      [ long "host-ipv6-addr"
      , metavar "IPV6"
      , help "An optional IPv6 address"
      ]

-- | Read an IP address of either family, as @--grpc-listen-address@ takes it.
parseNodeHostIPAddress :: String -> Either String IP
parseNodeHostIPAddress s =
  maybe (Left ("Failed to parse IP address: " ++ s)) Right (readMaybe s)

parseNodeHostIPv4Address :: String -> Either String IPv4
parseNodeHostIPv4Address s =
  maybe
    ( Left $
        "Failed to parse IPv4 address: "
          ++ s
          ++ ". If you want to specify an IPv6 address, use --host-ipv6-addr option."
    )
    Right
    (readMaybe s)

parseNodeHostIPv6Address :: String -> Either String IPv6
parseNodeHostIPv6Address s =
  maybe
    ( Left $
        "Failed to parse IPv6 address: "
          ++ s
          ++ ". If you want to specify an IPv4 address, use --host-addr option."
    )
    Right
    (readMaybe s)

parsePort :: Parser PortNumber
parsePort =
  option
    (bounded "PORT")
    $ mconcat
      [ long "port"
      , metavar "PORT"
      , help "The port number"
      , value 0 -- Use an ephemeral port
      ]

parseByronDelegationCert :: Parser FilePath
parseByronDelegationCert =
  strOption $
    mconcat
      [ long "byron-delegation-certificate"
      , metavar "FILEPATH"
      , help "Path to the delegation certificate"
      , completer (bashCompleter "file")
      ]

parseByronSigningKey :: Parser FilePath
parseByronSigningKey =
  strOption $
    mconcat
      [ long "byron-signing-key"
      , metavar "FILEPATH"
      , help "Path to the Byron signing key"
      , completer (bashCompleter "file")
      ]

parseOperationalCertFilePath :: Parser FilePath
parseOperationalCertFilePath =
  strOption $
    mconcat
      [ long "shelley-operational-certificate"
      , metavar "FILEPATH"
      , help "Path to the delegation certificate"
      , completer (bashCompleter "file")
      ]

parseBulkCredsFilePath :: Parser FilePath
parseBulkCredsFilePath =
  strOption $
    mconcat
      [ long "bulk-credentials-file"
      , metavar "FILEPATH"
      , help "Path to the bulk pool credentials file"
      , completer (bashCompleter "file")
      ]

-- TODO: pass the current KES evolution, not the KES_0
parseKESSource :: Parser KESSource
parseKESSource =
  asum
    [ KESKeyFilePath
        <$> strOption
          ( mconcat
              [ long "shelley-kes-key"
              , metavar "FILEPATH"
              , help "Path to the KES signing key."
              , completer (bashCompleter "file")
              ]
          )
    , KESAgentSocketPath
        <$> strOption
          ( mconcat
              [ long "shelley-kes-agent-socket"
              , metavar "SOCKET_FILEPATH"
              , help "Path to the KES Agent socket"
              , completer (bashCompleter "file")
              ]
          )
    ]

parseVrfKeyFilePath :: Parser FilePath
parseVrfKeyFilePath =
  strOption $
    mconcat
      [ long "shelley-vrf-key"
      , metavar "FILEPATH"
      , help "Path to the VRF signing key"
      , completer (bashCompleter "file")
      ]

parseBlsKeyFilePath :: Parser FilePath
parseBlsKeyFilePath =
  strOption $
    mconcat
      [ long "shelley-bls-key"
      , metavar "FILEPATH"
      , help $
          mconcat
            [ "Path to the BLS (Leios) signing key: a single text envelope, "
            , "or a JSON array of them to vote with every key that holds a "
            , "committee seat (e.g. a rotation pair, or a bundle of pool keys)."
            ]
      , completer (bashCompleter "file")
      ]

parseNodeAddress :: ReadM (Host, PortNumber)
parseNodeAddress = eitherReader parseHostPort

-- | Parse a @HOST:PORT@ pair. IPv6 addresses must be bracketed
-- (@[2001:db8::1]:3001@) to disambiguate the address colons from the
-- host/port separator; IPv4 addresses and hostnames are written bare
-- (@127.0.0.1:3001@).
--
-- This follows the URI authority syntax of RFC 3986 (§3.2.2), where an IPv6
-- literal is wrapped in brackets, which is what 'parseURIReference' implements.
-- The address inside the brackets is any representation accepted there (see
-- RFC 5952 for the recommended IPv6 text form). Note this is /not/ the SMTP
-- address-literal form of RFC 5321 (@[IPv6:...]@), which is a different syntax.
parseHostPort :: String -> Either String (Host, PortNumber)
parseHostPort s = do
  -- Parse as the authority component of a URI reference ("//host:port"), which
  -- handles bracketed IPv6, IPv4 and hostnames uniformly.
  uri <-
    maybe (Left ("parseHostPort: could not parse HOST:PORT from " ++ show s)) Right $
      parseURIReference ("//" ++ s)
  auth <- maybe (Left "parseHostPort: missing host and port.") Right (uriAuthority uri)
  let host = stripBrackets (uriRegName auth)
  when (null host) $ Left "parseHostPort: empty host."
  portStr <- case uriPort auth of
    ':' : p -> Right p
    _ -> Left "parseHostPort: missing port."
  p <-
    maybe (Left ("parseHostPort: non-numeric port " ++ show portStr)) Right (readMaybe @Integer portStr)
  if 0 <= p && p <= 65535
    then Right (Text.pack host, fromInteger p)
    else Left ("parseHostPort: port " ++ show p ++ " out of range: 0 - 65535.")
 where
  stripBrackets ('[' : rest) | not (null rest) && last rest == ']' = init rest
  stripBrackets other = other

parseTracerSocketMode :: Parser TracerConnection
parseTracerSocketMode =
  fmap (uncurry TracerConnection) $
    fmap
      (second (uncurry TracerConnectViaRemote))
      ( asum
          [ fmap ("Accept",) $
              option parseNodeAddress $
                mconcat
                  [ long "tracer-socket-network-accept"
                  , help "Accept incoming cardano-tracer connection on HOST:PORT"
                  , metavar "HOST:PORT"
                  ]
          , fmap ("Connect",) $
              option parseNodeAddress $
                mconcat
                  [ long "tracer-socket-network-connect"
                  , help "Connect to cardano-tracer listening on HOST:PORT"
                  , metavar "HOST:PORT"
                  ]
          ]
      )
      <|> fmap
        (second TracerConnectViaPipe)
        ( asum
            [ fmap ("Accept",) $
                strOption $
                  mconcat
                    [ long "tracer-socket-path-accept"
                    , help "Accept incoming cardano-tracer connection at local socket"
                    , completer (bashCompleter "file")
                    , metavar "FILEPATH"
                    ]
            , fmap ("Connect",) $
                strOption $
                  mconcat
                    [ long "tracer-socket-path-connect"
                    , help "Connect to cardano-tracer listening on a local socket"
                    , completer (bashCompleter "file")
                    , metavar "FILEPATH"
                    ]
            ]
        )

parseShutdownIPC :: Parser Fd
parseShutdownIPC =
  option
    (Fd <$> auto)
    $ mconcat
      [ long "shutdown-ipc"
      , metavar "FD"
      , help "Shut down the process when this inherited FD reaches EOF"
      , hidden
      ]

parseShutdownOn :: Parser ShutdownOn
parseShutdownOn =
  asum
    [ option (ShutdownAtSlot <$> bounded "SLOT") $
        mconcat
          [ long "shutdown-on-slot-synced"
          , metavar "SLOT"
          , help "Shut down the process after ChainDB is synced up to the specified slot"
          , hidden
          ]
    , option (ShutdownAtBlock <$> bounded "BLOCK") $
        mconcat
          [ long "shutdown-on-block-synced"
          , metavar "BLOCK"
          , help "Shut down the process after ChainDB is synced up to the specified block"
          , hidden
          ]
    ]

-- | An 'option' reader that parses a decimal integer and rejects values outside
-- the target type's bounds, rather than silently wrapping (as
-- @fromIntegral <$> auto@ would). The string argument names the value in the
-- error message.
--
-- Only plain decimal is accepted: an optional @-@ and then digits. 'readEither'
-- alone would also take Haskell's other integer literals and surrounding
-- whitespace, so @--port 0x1F1@ would bind port 497 and @--port 0o17@ port 15,
-- quietly, rather than being refused. @cardano-node@ refuses both — its
-- @parsePortNumber@ filters on 'isDigit' before reading — and an operator who
-- writes @0x1F1@ has made a mistake whichever tool reads it.
--
-- A leading @-@ is read and then caught by the lower-bound check below, so an
-- unsigned target reports the bound rather than a parse failure.
bounded :: forall a. (Bounded a, Integral a, Show a) => String -> ReadM a
bounded t = eitherReader $ \s -> do
  unless (isDecimal s) $ Left $ t <> " must be a decimal number, but was: " <> s
  i <- readEither @Integer s
  when (i < fromIntegral (minBound @a)) $ Left $ t <> " must not be less than " <> show (minBound @a)
  when (i > fromIntegral (maxBound @a)) $
    Left $
      t <> " must not be greater than " <> show (maxBound @a)
  pure (fromIntegral i)
 where
  isDecimal = \case
    '-' : digits -> allDigits digits
    digits -> allDigits digits
  allDigits ds = not (null ds) && all isDigit ds
