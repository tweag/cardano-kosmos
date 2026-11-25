let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input idx port role env =>
let dir = input.directory in
let spo_params = if role == "spo" then "--shelley-kes-key %{dir}/pools-keys/pool%{idx}/kes.skey --shelley-vrf-key %{dir}/pools-keys/pool%{idx}/vrf.skey --shelley-operational-certificate %{dir}/pools-keys/pool%{idx}/opcert.cert --byron-delegation-certificate %{dir}/pools-keys/pool%{idx}/byron-delegation.cert --byron-signing-key %{dir}/pools-keys/pool%{idx}/byron-delegate.key --shelley-bls-key %{dir}/pools-keys/pool%{idx}/bls.skey" else "" in
{
  command = "exec %{input.cardano_binaries.cardano_node} run --config %{dir}/configuration.yaml --topology %{dir}/node-data/node%{idx}/topology.json --database-path %{dir}/node-data/node%{idx}/db %{spo_params} --tracer-socket-path-connect %{dir}/socket/sock --socket-path %{dir}/socket/node%{idx}/sock --port %{port} --host-addr %{input.ip} > >(tee -a %{dir}/logs/node%{idx}/stdout.log) 2> >(tee -a %{dir}/logs/node%{idx}/stderr.log)",
  environment = env,
  depends_on = {
    cardano-tracer = { condition = 'process_healthy },
  },
  readiness_probe = {
    exec = {
      command = "[ -S ./%{input.directory}/socket/node%{idx}/sock ]",
    },
    initial_delay_seconds = 15,
    period_seconds = 5,
    max_failure = 5,
  },
}
