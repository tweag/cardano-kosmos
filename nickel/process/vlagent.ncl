let { ProcessConfig, .. } = import "../schemas/process-compose.ncl" in
fun input =>
{
  command = "vlagent -tmpDataPath=%{input.directory}/vlagent-data -fileCollector.glob='%{input.directory}/logs/**/node.json' -remoteWrite.url=http://%{input.ip}:%{input.victoria.logs_port}/insert/native -fileCollector.msgField=ns -fileCollector.timeField=at -fileCollector.streamFields=ns,sev",
  depends_on = {
    victoria-logs = { condition = 'process_healthy },
  },
}
