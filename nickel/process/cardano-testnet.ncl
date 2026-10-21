let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input =>
{
  command = "%{input.cardano_binaries.cardano_testnet} cardano --node-env %{input.directory} --enable-tracer --prometheus-listen-address %{input.prometheus.address}"
    ++ (if std.record.has_field "port" input.prometheus then " --prometheus-listen-port %{input.prometheus.port}" else ""),
  log_location = "%{input.directory}/logs/start-local-testnet.log",
  readiness_probe = {
    exec = {
      command = "[ -S ./%{input.directory}/socket/node1/sock ]",
    },
    initial_delay_seconds = 15,
    period_seconds = 5,
    max_failure = 5,
  },
}
