# Symbolic node labels, numbered per role: spo1..spoN, relay1..relayM.
# Must stay in sync with `node_label` in scripts/sidecar.sh.
fun scenario =>
  let roles =
    scenario.topology.nodes
    |> std.array.map (fun n => std.string.from_enum n.role)
  in
  # 1-based node index -> label
  fun idx =>
    let role = std.array.at (idx - 1) roles in
    let n =
      std.array.length
        (std.array.filter (fun r => r == role) (std.array.slice 0 idx roles))
    in
    "%{role}%{std.string.from_number n}"
