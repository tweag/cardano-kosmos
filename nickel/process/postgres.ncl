let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input =>
{
  command =
    let data_dir = "$PWD/%{input.directory}/postgres-data" in
    "rm -rf \"%{data_dir}\""
    ++ " && initdb --pgdata=\"%{data_dir}\" --username=%{input.postgres.user} --auth=trust --no-instructions >/dev/null"
    ++ " && exec postgres -D \"%{data_dir}\" -k \"%{data_dir}\""
    ++ " -h %{input.ip} -p %{std.string.from_number input.postgres.port}",
  readiness_probe = {
    exec = {
      command = "pg_isready -h %{input.ip} -p %{std.string.from_number input.postgres.port} -U %{input.postgres.user} -d postgres",
    },
    initial_delay_seconds = 1,
    period_seconds = 2,
    timeout_seconds = 1,
    success_threshold = 1,
    failure_threshold = 10,
  },
}
