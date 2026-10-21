let { Scenario, Group, .. } = import "./schemas/scenario.ncl"
in
let { TestnetConfig, .. } = import "./schemas/testnet.ncl"
in
let mkNodesArg | Array Group -> String =
  fun groups =>
    groups
      |> std.array.map (fun r => std.array.replicate r.count (std.string.from_enum r.role))
      |> std.array.flatten
      |> std.array.sort (std.function.flip std.string.compare)
      |> std.string.join ","
in
let mkTestnetConfig | Scenario -> TestnetConfig = fun s => {
  nodes_arg = mkNodesArg s.topology.groups,
  genesis = s.genesis,
  testnet_magic = s.topology.magic,
}
in mkTestnetConfig

