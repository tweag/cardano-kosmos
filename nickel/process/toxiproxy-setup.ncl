let { for_each, .. } = import "../prelude.ncl" in
let { map, range, flatten, at, .. } = std.array in
let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in

let
  toxiproxyCreate = fun idx ip proxyPort upstreamPort =>
    "toxiproxy-cli create --listen %{ip}:%{proxyPort} --upstream %{ip}:%{upstreamPort} node%{idx}",

  toxiproxyLatency = fun direction latency_ms jitter_ms node_id =>
    let toxicity_name = fun dir_arg => "toxicity_%{dir_arg}_%{node_id}" in
    let mk_c = fun dir_arg =>
      "toxiproxy-cli toxic add -n %{toxicity_name dir_arg} -%{dir_arg} -t latency -a latency=%{latency_ms} -a jitter=%{jitter_ms} node%{node_id}"
    in
    match {
      'upsteam => [mk_c "u"],
      'downstream => [mk_c "d"],
      'both => [mk_c "u", mk_c "d"],
    } direction,
in
let mkCommand = fun input scenario portsOfNodes =>
  let
    forEachNode = for_each (range 1 (scenario.topology.num_of_nodes + 1))
  in let
    toxiproxyCreateCommands = forEachNode
      (fun idx => toxiproxyCreate idx input.ip (input.node_ports_base + idx) (at (idx - 1) portsOfNodes)),

    applyFaultCommands = flatten
      (for_each scenario.faults 
        (match {
          'isolate node_ids => map (fun id => "toxiproxy-cli toggle node%{id}") node_ids,
          'latency setup => flatten (for_each setup.nodes (toxiproxyLatency setup.direction setup.latency_ms setup.jitter_ms)),
        })
      )
  in std.string.join "\n" (toxiproxyCreateCommands @ applyFaultCommands)
in
fun input scenario portsOfNodes =>
{
  command = mkCommand input scenario portsOfNodes,
  environment = [
  ],
  depends_on = {
    toxiproxy-server = { condition = 'process_healthy },
  },
  availability = {
    restart = "no",
  },
}
