let { Scenario, Node, .. } = import "./schemas/scenario.ncl"
in
let { InputParams, CardanoBinaries, TestnetConfig, .. } = import "./schemas/testnet.ncl"
in
let mkNodesArg | CardanoBinaries -> Array Node -> String =
  fun cardano_binaries nodes =>
    nodes
      |> std.array.map (fun n => std.string.from_enum n.role)
      |> std.array.sort (std.function.flip std.string.compare)
      |> std.array.map (fun n => "%{n}:node-bin=%{cardano_binaries.cardano_node}")
      |> std.string.join ","
in
let mkTestnetConfig | CardanoBinaries -> InputParams -> Scenario -> TestnetConfig = fun cardano_binaries input s => {
  nodes_arg = mkNodesArg cardano_binaries s.topology.nodes,
  genesis = s.genesis,
  testnet_magic = s.topology.magic,
  proxy = match { 'none => "none", 'envoy params => "envoy%{params.port}" } input.proxy,
  ip = input.ip,
  node_ports_base = input.node_ports_base,
  trace_options = input.trace_options,
}
in mkTestnetConfig

