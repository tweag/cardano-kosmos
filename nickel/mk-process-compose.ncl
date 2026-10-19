let
  { Project, .. } = import "./schemas/process-compose.ncl",
in
let
  subprocess_guard = import "./process/subprocess-guard.ncl",
  mk_cardano_testnet = import "./process/cardano-testnet.ncl",
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
  mk_proxy = fun input => match {
    'none => {},
    'envoy params => { envoy = mk_envoy input.directory input.ip params.port, }
  } input.proxy,
in fun old_input cardano_bins scenario portsOfNodes =>
let input = old_input & { cardano_binaries = cardano_bins } in
{
  version = "0.5",
  name = "peras-testnet-" ++ scenario.name,
  processes = {
    subprocess-guard = subprocess_guard,
    cardano-testnet = mk_cardano_testnet input scenario,
    chairman = mk_chairman input scenario,
    victoria-logs = mk_victoria_logs input,
    vlagent = mk_vlagent input scenario portsOfNodes,
    oracle = oracle_process,
  } & (if std.record.has_field "port" input.prometheus then {
    victoria-metrics = mk_victoria_metrics input scenario portsOfNodes,
    grafana = mk_grafana input,
    sidecar = mk_sidecar input scenario,
    canary = mk_canary input scenario,
  } else {}) & ( mk_proxy input ),
} | Project
