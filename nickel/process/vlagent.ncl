let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input scenario portsOfNodes =>
let label_of = fun idx => std.array.at (idx - 1) scenario.topology.node_labels in
# cardano-tracer writes each node's logs to logs/<host>_<port>/node.json.
# One glob per node, each paired (by position) with an extraFields entry
# tagging its lines with the symbolic `node` label.
let per_node =
  std.array.range 1 (std.array.length portsOfNodes + 1)
  |> std.array.map (fun idx =>
    let port = std.string.from_number (std.array.at (idx - 1) portsOfNodes) in
    "-fileCollector.glob='%{input.directory}/logs/*_%{port}/node.json' "
    ++ "-fileCollector.extraFields='{\"node\":\"%{label_of idx}\"}'")
  |> std.string.join " "
in
{
  command = "vlagent -tmpDataPath=%{input.directory}/vlagent-data %{per_node} -remoteWrite.url=http://%{input.ip}:%{input.victoria.logs_port}/insert/native -fileCollector.msgField=ns -fileCollector.timeField=at -fileCollector.streamFields=node,ns,sev",
  depends_on = {
    victoria-logs = { condition = 'process_healthy },
  },
}
