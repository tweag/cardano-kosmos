let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
{
  command = m%"
    trap 'pkill cardano; exit 1' TERM INT HUP
    echo 'When cardano-testnet dies too early, it fails to setup a signal handler, which in turn keeps all of its subprocesses alive.'
    echo 'This process watches for that, and kills the subprocesses if necessary.'
    sleep 5
    until [ -S ./devnet-env/socket/node1/sock ]; do
      sleep 1 &
      wait $!
    done
  "%,
  availability = {
    restart = "no",
  },
}
