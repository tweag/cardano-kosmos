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
  mk_toxiproxy_server = import "./process/toxiproxy-server.ncl",
  mk_toxiproxy_setup = import "./process/toxiproxy-setup.ncl",
  mk_sidecar = import "./process/sidecar.ncl",
  oracle_process = import "./process/oracle.ncl",
in fun input scenario portsOfNodes =>
{
  version = "0.5",
  name = "peras-testnet-" ++ scenario.name,
  processes = {
    subprocess-guard = subprocess_guard,
    cardano-testnet = mk_cardano_testnet input scenario,
    chairman = mk_chairman input scenario,
    victoria-logs = mk_victoria_logs input,
    vlagent = mk_vlagent input,
    toxiproxy-server = mk_toxiproxy_server input,
    toxiproxy-setup = mk_toxiproxy_setup input scenario portsOfNodes,
    oracle = oracle_process,
  } & (if std.record.has_field "port" input.prometheus then {
    victoria-metrics = mk_victoria_metrics input,
    grafana = mk_grafana input,
    sidecar = mk_sidecar input scenario,
  } else {}),
} | Project
