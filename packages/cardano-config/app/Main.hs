-- | The @cardano-config@ command-line tool. It exposes three subcommands:
--
--   * @cardano-config resolve@ resolves a @cardano-node@ configuration
--     (per-component defaults, the configuration file and the CLI flags),
--     merging and resolving it exactly as a node would, and prints the complete
--     result as YAML.
--
--   * @cardano-config schema@ dumps the configuration JSON Schema (for the
--     whole configuration or a single component), derived from the same codecs.
--
--   * @cardano-config migrate@ reshapes a configuration into the recommended
--     @{ $schema, Version, MinNodeVersion, Configuration }@ envelope and prints
--     it as JSON (a purely structural migration, preserving the values).
--
-- The commands themselves live in the @cardano-config-commands@ sublibrary
-- ('configCommands'), so other tools can reuse them; this executable is just a
-- thin driver that wires them into a top-level subparser.
module Main (main) where

import Cardano.Configuration.Commands (configCommands)
import Control.Monad (join)
import Options.Applicative

main :: IO ()
main = join $ execParser opts
 where
  opts =
    info
      (hsubparser configCommands <**> helper)
      ( fullDesc
          <> progDesc "Parse, resolve and document the cardano-node configuration."
      )
