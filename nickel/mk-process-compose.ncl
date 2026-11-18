let { Project, .. } = import "./schemas/process-compose.ncl" in
let { map, .. } = std.array in
let
  mk_cardano_tracer = import "./process/cardano-tracer.ncl",
  mk_cardano_node = import "./process/cardano-node.ncl",
  mk_chairman = import "./process/chairman.ncl",
  mk_victoria_logs = import "./process/victoria-logs.ncl",
  mk_vlagent = import "./process/vlagent.ncl",
  mk_victoria_metrics = import "./process/victoria-metrics.ncl",
  mk_grafana = import "./process/grafana.ncl",
  mk_sidecar = import "./process/sidecar.ncl",
  mk_canary = import "./process/canary.ncl",
  mk_envoy = import "./process/envoy.ncl",
  oracle_process = import "./process/oracle.ncl",
in
let
  mk_proxy = fun input depends_on_first_node => match {
    'none => {},
    'envoy params => { envoy = mk_envoy input.directory input.ip params.port & depends_on_first_node, }
  } input.proxy,
in
let mk_node_name = fun n => "node%{n.idx}-%{n.node.role}-%{n.node.name}" in
let
  mk_cardano_nodes = fun input topology env =>
    topology
      |> map (fun n => {
        field = mk_node_name n,
        value = mk_cardano_node input (n.idx + 1) n.port n.node.role env
      })
      |> std.record.from_array,
in fun old_input cardano_bins scenario topology =>
let input = old_input & { cardano_binaries = cardano_bins } in
let first_node = std.array.at 0 topology in
let depends_on_first_node = { depends_on = { "%{mk_node_name first_node}" = { condition = 'process_healthy } } } in
{
  version = "0.5",
  name = "peras-testnet-" ++ scenario.name,
  processes = {
    cardano-tracer = mk_cardano_tracer input scenario,
    chairman = mk_chairman input scenario & depends_on_first_node,
    victoria-logs = mk_victoria_logs input & depends_on_first_node,
    vlagent = mk_vlagent input scenario topology,
    oracle = oracle_process & depends_on_first_node,
  } & (if std.record.has_field "port" input.prometheus then {
    victoria-metrics = mk_victoria_metrics input scenario topology & depends_on_first_node,
    grafana = mk_grafana input,
    sidecar = mk_sidecar input scenario & depends_on_first_node,
    canary = mk_canary input scenario,
  } else {}) & ( mk_proxy input depends_on_first_node ) & mk_cardano_nodes input topology scenario.env,
} | Project
