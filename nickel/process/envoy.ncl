let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input =>
{
  command = "envoy -c %{input.directory}/envoy.json",
  environment = [
  ],
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
  readiness_probe = {
    exec = {
      command = "curl -sf http://%{input.ip}:%{input.envoy.port}/ready",
    },
    initial_delay_seconds = 1,
    period_seconds = 2,
    timeout_seconds = 1,
    success_threshold = 1,
    failure_threshold = 5,
  }
}
