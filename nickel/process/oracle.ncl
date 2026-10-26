# This is an optional process that checks if there is a script to run.
# Created for a local work on the testnet, to run some commands after
# the testnet has started. The path is gitignored.
let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
let oracle_path = "./scripts/oracle.sh" in
{
  command = m%"
    if [ -f "%{oracle_path}" ]; then
      echo "Running oracle process %{oracle_path}"
      bash %{oracle_path}
    else
      echo "No oracle to run. You might want to consider adding one at %{oracle_path}."
    fi
  "%,
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
}
