let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input scenario =>
let dir = input.directory in
{
  command = "exec %{input.cardano_binaries.cardano_tracer} --config %{dir}/cardano-tracer-config.json >> %{dir}/logs/cardano-tracer.stdout.log 2>> %{dir}/logs/cardano-tracer.stderr.log",
  environment = scenario.env,
  readiness_probe = {
    exec = {
      command = "curl -sf http://%{input.prometheus.address}:%{std.string.from_number input.prometheus.port}/",
    },
    initial_delay_seconds = 2,
    period_seconds = 2,
    timeout_seconds = 1,
    success_threshold = 1,
    failure_threshold = 60,
  }
}
