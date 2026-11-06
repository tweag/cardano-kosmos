let { Scenario, Node, .. } = import "./schemas/scenario.ncl"
in
let { TestnetConfig, .. } = import "./schemas/testnet.ncl"
in
let mkNodesArg | Array Node -> String =
  fun nodes =>
    nodes
      |> std.array.map (fun n => std.string.from_enum n.role)
      |> std.array.sort (std.function.flip std.string.compare)
      |> std.string.join ","
in
let mkTestnetConfig | Scenario -> TestnetConfig = fun s => {
  nodes_arg = mkNodesArg s.topology.nodes,
  genesis = s.genesis,
  testnet_magic = s.topology.magic,
}
in mkTestnetConfig

