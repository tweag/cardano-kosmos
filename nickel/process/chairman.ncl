let
  { ProcessConfig, .. } = import "../schemas/process-compose.ncl",
in
let mkSocketPaths = fun numOfNodes dir =>
  std.string.join " " (std.array.map (fun i => "--socket-path %{dir}/socket/node%{i}/sock") (std.array.range 1 (numOfNodes + 1)))
in
fun input scenario =>
{
  command = "%{input.cardano_binaries.cardano_node_chairman} run --config %{input.directory}/configuration.yaml --timeout %{24 * 60 * 60} --require-progress 10" ++ " " ++ mkSocketPaths scenario.topology.num_of_nodes input.directory,
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
}
