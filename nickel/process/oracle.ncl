let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
let oracle_path = "./scripts/oracle.sh" in
{
  command = m%"
    if [ -f "%{oracle_path}" ]; then
      echo "Running oracle process %{oracle_path}"
      bash %{oracle_path}
    else
      echo "No oracle to run."
    fi
  "%,
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
}
