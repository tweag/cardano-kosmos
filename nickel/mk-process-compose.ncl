let
  { Scenario, count_nodes, .. } = import "./schemas/scenario.ncl",
  { Project, .. } = import "./schemas/process-compose.ncl",
  { InputParams, .. } = import "./schemas/testnet.ncl",
in
let
  subprocess_guard = import "./process/subprocess-guard.ncl",
  mk_cardano_testnet = import "./process/cardano-testnet.ncl",
  mk_chairman = import "./process/chairman.ncl",
  mk_victoria_logs = import "./process/victoria-logs.ncl",
  mk_vlagent = import "./process/vlagent.ncl",
  mk_victoria_metrics = import "./process/victoria-metrics.ncl",
  mk_grafana = import "./process/grafana.ncl",
  mk_postgres = import "./process/postgres.ncl",
  mk_sidecar = import "./process/sidecar.ncl",
in fun input scenario =>
{
  version = "0.5",
  name = "peras-testnet-" ++ scenario.name,
  processes = {
    subprocess-guard = subprocess_guard,
    cardano-testnet = mk_cardano_testnet input scenario,
    chairman = mk_chairman input scenario,
    victoria-logs = mk_victoria_logs input,
    vlagent = mk_vlagent input,
  } & (if std.record.has_field "port" input.prometheus then {
    victoria-metrics = mk_victoria_metrics input,
    grafana = mk_grafana input,
    postgres = mk_postgres input,
    sidecar = mk_sidecar input scenario,
  } else {}),
} | Project
