let { Scenario, Genesis, .. } = import "./scenario.ncl"
in
let ProcessCompose = import "./process-compose.ncl"
in
let export = {
  cardano_binary_names = [
    "cardano-node",
    "cardano-node-chairman",
    "cardano-cli",
    "cardano-testnet",
    "cardano-tracer",
  ],

  # look cardano binaries in cabal's cache plan
  found_cardano_binaries =
    let cache_plan = import "../../dist-newstyle/cache/plan.json" in
      cache_plan."install-plan"
      |> std.array.fold_left (fun acc item =>
        if std.record.has_field "bin-file" item
          && item."component-name" == "exe:%{item."pkg-name"}"
          && std.array.elem item."pkg-name" cardano_binary_names
        then
          [{ field = std.string.replace "-" "_" item."pkg-name", value = item."bin-file" }] @ acc
        else acc
      ) [],

  CardanoBinaries =
    std.array.fold_left (fun acc b => 
      acc & { "%{b.field}" | String | default = b.value }
    ) {} found_cardano_binaries,

  InputParams = {
    directory | String,
    cardano_binaries | CardanoBinaries | default = {},
    ip | String | default = "127.0.0.1",
    node_ports_base | Number | default = 5000,
    victoria = {
      logs_port | Number | default = 9428,
      metrics_port | Number | default = 8428,
    },
    grafana = {
      port | Number | default = 3000,
    },
    prometheus = {
      address | String | default = "127.0.0.1",
      port | Number | default = 9090,
    },
    toxiproxy = {
       port | Number | default = 8474,
    },
  },
  TestnetConfig = {
    nodes_arg | String,
    genesis | Genesis,
    testnet_magic | Number,
  },
}
in export
