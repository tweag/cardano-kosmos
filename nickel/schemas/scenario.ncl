let export = {
  Group = {
    name | String,
    role | [| 'spo, 'relay |],
    count | Number,
    stake | Number | optional,
  },

  count_dreps | Array Group -> Number =
    fun groups => std.array.fold_left
      (fun acc group => acc + (if group.role == 'spo then group.count else 0)) 0 groups,

  count_nodes | Array Group -> Number =
    fun groups => std.array.fold_left (fun acc group => acc + group.count) 0 groups,
  
  Genesis = {
    epoch_length_slots | Number | default = 360,
    slot_length_seconds | Number | default = 0.2,
    security_param_k | Number | default = 5,
    active_slot_coeff_f | Number | default = 0.05,
    num_dreps | Number,
    max_lovelace_supply | Number,
    start_directly_in_dijkstra | Bool | default = true,
  },

  Fault = [|
    'isolate { nodes | Array Number },
    'latency {
      nodes | Array Number,
      direction | [| 'upstream, 'downstream, 'both |] | default = 'both, 
      latency_ms | Number | default = 200, 
      jitter_ms | Number | default = 0
    },
  |],

  Scenario = {
    name | String,
    description | String,
    topology = {
      magic | Number,
      groups | Array Group,
    },
    genesis | Genesis,
    faults | Array Fault | optional,
    observability | {
      trace_filters | (Array String),
    } | optional ,
    env | { _ | String } | optional,
  },
}
in export 
