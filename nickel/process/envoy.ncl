let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun directory ip envoy_port =>
{
  command = "envoy -c %{directory}/envoy.json",
  environment = [
  ],
  readiness_probe = {
    exec = {
      command = "curl -sf http://%{ip}:%{envoy_port}/ready",
    },
    initial_delay_seconds = 1,
    period_seconds = 2,
    timeout_seconds = 1,
    success_threshold = 1,
    failure_threshold = 5,
  }
}
