let { at, map, range, .. } = std.array in
let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input scenario portsOfNodes =>
# Symbolic node labels, numbered per role: spo1..spoN, relay1..relayM.
let roles =
  scenario.topology.groups
  |> std.array.flat_map (fun g =>
    std.array.replicate g.count (std.string.from_enum g.role))
in
let label_of = fun idx =>
  let role = at (idx - 1) roles in
  let n =
    std.array.length
      (std.array.filter (fun r => r == role) (std.array.slice 0 idx roles))
  in
  "%{role}%{std.string.from_number n}"
in
{
  # VictoriaMetrics scrapes the cardano-tracer prometheus endpoint. The
  # scrape config must live in a real file passed via `-promscrape.config`;
  # VictoriaMetrics does NOT read an inline config from an environment
  # variable, and `-promscrape.config=/dev/null` disables scraping entirely
  # (which is why the dashboards showed "no data"). So we materialise the
  # config on disk first, then start the server pointing at it.
  command =
    let scrape_config = "%{input.directory}/vm-scrape.yml" in
    let node_rules =
      std.string.join "" (map
        (fun idx =>
          let port = std.string.from_number (at (idx - 1) portsOfNodes) in
          "      - source_labels: [node_name]\n"
          ++ "        regex: '.*_%{port}'\n"
          ++ "        target_label: node\n"
          ++ "        replacement: '%{label_of idx}'\n"
        )
        (range 1 (std.array.length portsOfNodes + 1))
      )
    in
    let scrape_yaml =
      "scrape_configs:\n"
      ++ "  - job_name: \"cardano-tracer\"\n"
      ++ "    http_sd_configs:\n"
      ++ "      - url: \"http://%{input.prometheus.address}:%{std.string.from_number input.prometheus.port}/targets\"\n"
      ++ "    metric_relabel_configs:\n"
      ++ node_rules
    in
    "printf '%s' '%{scrape_yaml}' > \"%{scrape_config}\""
    ++ " && victoria-metrics -promscrape.config=\"%{scrape_config}\" -storageDataPath=%{input.directory}/victoria-metrics-data",
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
  readiness_probe = {
    exec = {
      command = "curl -sf http://%{input.ip}:%{input.victoria.metrics_port}/",
    },
    initial_delay_seconds = 1,
    period_seconds = 2,
    timeout_seconds = 1,
    success_threshold = 1,
    failure_threshold = 5,
  },
}
