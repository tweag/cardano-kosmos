# Tagged fault payloads cannot be exported directly to JSON.
fun scenario =>
(std.record.remove "faults" scenario) & {
  faults = std.array.map
    (match {
      'latency setup => setup & { kind = "latency" },
      'isolate nodes => { kind = "isolate", nodes = nodes },
    }) scenario.faults,
}
