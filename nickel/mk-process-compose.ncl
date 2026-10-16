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
      command = "victoria-metrics -promscrape.config=/dev/null -storageDataPath=%{input.directory}/victoria-metrics-data",
      environment = [
        m%"VM_promscrape_config='
        scrape_configs:
          - job_name: "cardano-tracer"
            http_sd_configs:
              - url: 'http://%{input.prometheus.address}:%{input.prometheus.port}/targets'
        '"%
      ],
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
  } else {}),
}
in mkProcessCompose
