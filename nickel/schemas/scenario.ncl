let { sum, .. } = import "./../prelude.ncl" in
let { map, filter, fold_left, generate, partition, length, .. } = std.array in

# Makes sure that '.stake' is always == 1 in topology
# if a field is missing, it will be derived
let StakeConstraint = std.contract.custom (fun label groups =>
  let spos = filter (fun g => g.role == 'spo) groups in
  let partitioned = spos |> partition (std.record.has_field "stake") in
  let explicit = partitioned.right |> map (fun g => g.stake) |> sum in
  let missing = length partitioned.wrong in
  if explicit > 1 then
    std.contract.blame_with_message 
      "Total explicit stake ratios already exceed 1. Current sum is %{std.string.from_number explicit}." 
      label
  else if missing > 0 && explicit == 1 then
    std.contract.blame_with_message 
      "Some SPO groups are missing a 'stake' field, but explicit stakes already sum to 1." 
      label
  else if missing == 0 && explicit != 1 then
    std.contract.blame_with_message
      "Total stake ratios must sum to exactly 1. Current sum is %{std.string.from_number explicit}." 
      label
  else
    let remaining = 1 - explicit in
    let derived = if missing > 0 then remaining / missing else 0 in
    'Ok (groups
      |> map (fun g =>
        if g.role == 'spo && !(std.record.has_field "stake" g)
        then g & { stake = derived }
        else g
      )
    )
) in

let export = {
  Group = {
    name | String,
    role | [| 'spo, 'relay |],
    count | Number,
    stake | Number | optional,
  },

  count_dreps | Array Group -> Number =
    fun groups => groups
      |> map (fun g => if g.role == 'spo then g.count else 0)
      |> sum,

  count_nodes | Array Group -> Number =
    fun groups => groups
      |> map (fun g => g.count)
      |> sum,

  groupsWithIndices | Array Group -> Array { group | Group, indices | Array Number } =
    fun groups => groups
      |> filter (fun g => g.role == 'spo)
      |> fold_left (fun acc g => 
          let start = acc.next_index in
          let count = g.count in
          let indices' = generate (fun i => start + i) count in
          {
            next_index = start + count,
            list = acc.list @ [{ group = g, indices = indices' }]
          }
        ) { next_index = 1, list = [] }
      |> std.record.get "list",
  
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
      groups | Array Group | StakeConstraint,
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
