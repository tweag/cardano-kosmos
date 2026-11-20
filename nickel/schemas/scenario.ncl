let { sum, .. } = import "./../prelude.ncl" in
let { map, filter, fold_left, generate, partition, length, flatten, .. } = std.array in

# Makes sure that '.stake' is always == 1 in topology
# if a field is missing, it will be derived
let StakeConstraint = std.contract.custom (fun label nodes =>
  let spos = filter (fun n => n.role == 'spo) nodes in
  let partitioned = spos |> partition (std.record.has_field "stake") in
  let explicit = partitioned.right |> map (fun n => n.stake) |> sum in
  let missing = length partitioned.wrong in
  if explicit > 1 then
    std.contract.blame_with_message 
      "Total explicit stake ratios already exceed 1. Current sum is %{std.string.from_number explicit}." 
      label
  else if missing > 0 && explicit == 1 then
    std.contract.blame_with_message 
      "Some SPO nodes are missing a 'stake' field, but explicit stakes already sum to 1." 
      label
  else if missing == 0 && explicit != 1 then
    std.contract.blame_with_message
      "Total stake ratios must sum to exactly 1. Current sum is %{std.string.from_number explicit}." 
      label
  else
    let remaining = 1 - explicit in
    let derived = if missing > 0 then remaining / missing else 0 in
    'Ok (nodes
      |> map (fun n =>
        if n.role == 'spo && !(std.record.has_field "stake" n)
        then n & { stake = derived }
        else n
      )
    )
) in

let export = {
  Node = {
    name | String,
    role | [| 'spo, 'relay |],
    stake | Number | optional,
  },

  Link = {
    from | String,
    to | String,
  },

  Topology = {
    magic | Number,
    nodes | Array Node | StakeConstraint,
    links | Array Link,
    num_of_nodes | Number | default = count_nodes nodes,
    # Symbolic node labels, numbered per role: spo1..spoN, relay1..relayM.
    # Indexed by position in `nodes` (0-based).
    node_labels | Array String | default = mk_node_labels nodes,
  },

  count_dreps | Array Node -> Number = fun nodes =>
    nodes
      |> filter (fun n => n.role =='spo)
      |> map (fun n => 1)
      |> sum,

  count_nodes | Array Node -> Number = fun nodes =>
    nodes
      |> map (fun n => 1)
      |> sum,

  mk_node_labels | Array Node -> Array String = fun nodes =>
    let roles = nodes |> map (fun n => std.string.from_enum n.role) in
    generate
      (fun i =>
        let role = std.array.at i roles in
        let n = length (filter (fun r => r == role) (std.array.slice 0 (i + 1) roles)) in
        "%{role}%{std.string.from_number n}")
      (length roles),

  mk_neighbours | String -> Array Node -> Array Link = fun name nodes =>
    nodes
      |> filter (fun n => n.name != name)
      |> map (fun n => { from = name, to = n.name } ),

  mk_complete_links | Array Node -> Array Link = fun nodes =>
    nodes
      |> map (fun n => mk_neighbours n.name nodes)
      |> flatten,

  Genesis = {
    epoch_length_slots | Number | default = 360,
    slot_length_seconds | Number | default = 0.2,
    security_param_k | Number | default = 5,
    active_slot_coeff_f | Number | default = 0.05,
    num_dreps | Number,
    max_lovelace_supply | Number,
    start_directly_in_dijkstra | Bool | default = true,
    peras | { _ | Dyn } | default = {},
  },

  Fault = [|
    'isolate (Array Number),
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
    topology | Topology, 
    genesis | Genesis,
    faults | Array Fault | default = [],
    observability | {
      trace_filters | (Array String),
    } | optional ,
    env | Array String | default = [],
  },
}
in export 
