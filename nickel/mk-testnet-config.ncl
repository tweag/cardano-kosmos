let { Scenario, Node, .. } = import "./schemas/scenario.ncl"
in
let { InputParams, TestnetConfig, .. } = import "./schemas/testnet.ncl"
in
let mkNodesArg | Array Node -> String =
  fun nodes =>
    nodes
      |> std.array.map (fun n => std.string.from_enum n.role)
      |> std.array.sort (std.function.flip std.string.compare)
      |> std.string.join ","
in
let mkTestnetConfig | InputParams -> Scenario -> TestnetConfig = fun input s => {
  nodes_arg = mkNodesArg s.topology.nodes,
  genesis = s.genesis,
  testnet_magic = s.topology.magic,
  proxy = match { 'none => "none", 'envoy params => "envoy%{params.port}" } input.proxy,
  ip = input.ip,
  node_ports_base = input.node_ports_base,
}
in mkTestnetConfig

