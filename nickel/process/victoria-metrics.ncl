let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input =>
{
  # VictoriaMetrics scrapes the cardano-tracer prometheus endpoint. The
  # scrape config must live in a real file passed via `-promscrape.config`;
  # VictoriaMetrics does NOT read an inline config from an environment
  # variable, and `-promscrape.config=/dev/null` disables scraping entirely
  # (which is why the dashboards showed "no data"). So we materialise the
  # config on disk first, then start the server pointing at it.
  command =
    let scrape_config = "%{input.directory}/vm-scrape.yml" in
    let scrape_yaml =
      "scrape_configs:\n"
      ++ "  - job_name: \"cardano-tracer\"\n"
      ++ "    http_sd_configs:\n"
      ++ "      - url: \"http://%{input.prometheus.address}:%{std.string.from_number input.prometheus.port}/targets\"\n"
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
