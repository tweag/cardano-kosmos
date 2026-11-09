fun delay_ms scenario => (std.record.remove "description" (std.record.remove "name" scenario)) & {
  name = scenario.name ++ "-delay-%{delay_ms}",
  description = scenario.description ++ "; %{delay_ms} ms each direction, no jitter",
  faults | force = ['latency {
    nodes = std.array.range 1 (scenario.topology.num_of_nodes + 1),
    direction = 'both,
    latency_ms = delay_ms,
    jitter_ms = 0,
  }],
}
