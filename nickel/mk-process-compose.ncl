let { Scenario, count_nodes, .. } = import "./schemas/scenario.ncl"
in
let ProcessCompose = import "./schemas/process-compose.ncl"
in
let { InputParams, .. } = import "./schemas/testnet.ncl"
in
let mkSocketPaths = fun numOfNodes dir =>
  std.string.join " " (std.array.map (fun i => "--socket-path %{dir}/socket/node%{i}/sock") (std.array.range 1 (numOfNodes + 1)))
in
let mkProcessCompose | InputParams -> Scenario -> ProcessCompose = fun input scenario =>
let logs_path = "%{input.directory}/logs" in
{
  version = "0.5",
  name = "peras-testnet-" ++ scenario.name,
  processes = {
    cardano-testnet = {
      command = "%{input.cardano_binaries.cardano_testnet} cardano --node-env %{input.directory} --enable-tracer --prometheus-listen-address %{input.prometheus.address}"
        ++ (if std.record.has_field "port" input.prometheus then " --prometheus-listen-port %{input.prometheus.port}" else ""),
      log_location = "%{logs_path}/start-local-testnet.log",
      readiness_probe = {
        exec = {
          command = "[ -S ./%{input.directory}/socket/node1/sock ]",
        },
        initial_delay_seconds = 15,
        period_seconds = 5,
        max_failure = 5,
      },
      shutdown = {
        command = "pkill -9 -P $$",
        signal = 9
      }
    },

    chairman = {
      command = "%{input.cardano_binaries.cardano_node_chairman} run --config %{input.directory}/configuration.yaml --timeout %{24 * 60 * 60} --require-progress 10" ++ " " ++ mkSocketPaths (count_nodes scenario.topology.groups) input.directory,
      depends_on = { 
        cardano-testnet = { condition = 'process_healthy },
      },
    },

    victoria-logs = {
      command = "victoria-logs -storageDataPath=%{input.directory}/victoria-logs-data",
      depends_on = {
        cardano-testnet = { condition = 'process_healthy },
      },
      readiness_probe = {
        exec = {
          command = "curl -sf http://%{input.ip}:%{input.victoria.logs_port}/",
        },
        initial_delay_seconds = 1,
        period_seconds = 2,
        timeout_seconds = 1,
        success_threshold = 1,
        failure_threshold = 5,
      },
    },

    vlagent = {
      command = "vlagent -tmpDataPath=%{input.directory}/vlagent-data -fileCollector.glob='%{logs_path}/**/node.json' -remoteWrite.url=http://%{input.ip}:%{input.victoria.logs_port}/insert/native -fileCollector.msgField=ns -fileCollector.timeField=at -fileCollector.streamFields=ns,sev",
      depends_on = {
        victoria-logs = { condition = 'process_healthy },
      },
    },
  } & (if std.record.has_field "port" input.prometheus then {
    victoria-metrics = {
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
    },

    grafana = {
      # Resolve grafana's homepath (bundled defaults + frontend assets) from the
      # `grafana` binary on PATH so this stays self-contained under `nix develop`.
      # Paths are passed as absolute `cfg:` overrides because grafana resolves
      # relative paths against its homepath (the nix store), not the cwd.
      #
      # The core datasource plugins (prometheus, loki) live read-only in the nix
      # store ($GRAFANA_CORE_PLUGINS, set by the devShell). Grafana wants a
      # *writable* plugins dir (it creates subdirs there, e.g. for preinstalled
      # apps), so we symlink the store plugins into a writable dir under the
      # devnet directory and point grafana at that. Preinstall is disabled so
      # grafana doesn't try to download its default bundled apps.
      command =
        let plugins_dir = "$PWD/%{input.directory}/grafana-plugins" in
        "mkdir -p \"%{plugins_dir}\""
        ++ " && for p in \"$GRAFANA_CORE_PLUGINS\"/*; do ln -sfn \"$(readlink -f \"$p\")\" \"%{plugins_dir}/$(basename \"$p\")\"; done"
        ++ " && grafana server"
        ++ " --homepath \"$(dirname $(dirname $(readlink -f $(command -v grafana))))/share/grafana\""
        ++ " cfg:default.paths.data=\"$PWD/%{input.directory}/grafana-data\""
        ++ " cfg:default.paths.logs=\"$PWD/%{logs_path}/grafana\""
        ++ " cfg:default.paths.plugins=\"%{plugins_dir}\""
        ++ " cfg:default.paths.provisioning=\"$PWD/grafana/provisioning\""
        ++ " cfg:default.plugins.preinstall_disabled=true"
        ++ " cfg:default.server.http_addr=%{input.ip}"
        ++ " cfg:default.server.http_port=%{std.string.from_number input.grafana.port}",
      environment = [
        "GF_SECURITY_ADMIN_USER=cardano",
        "GF_SECURITY_ADMIN_PASSWORD=cardano",
        "GF_AUTH_ANONYMOUS_ENABLED=true",
        "GF_FEATURE_TOGGLES_splashScreen=false",
      ],
      depends_on = {
        victoria-metrics = { condition = 'process_healthy },
      },
      readiness_probe = {
        exec = {
          command = "curl -sf http://%{input.ip}:%{std.string.from_number input.grafana.port}/api/health",
        },
        initial_delay_seconds = 2,
        period_seconds = 2,
        timeout_seconds = 1,
        success_threshold = 1,
        failure_threshold = 10,
      },
    },
  } else {}),
}
in mkProcessCompose
