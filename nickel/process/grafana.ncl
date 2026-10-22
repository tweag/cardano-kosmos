let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input =>
{
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
    ++ " cfg:default.paths.logs=\"$PWD/%{input.directory}/logs/grafana\""
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
  }
}
