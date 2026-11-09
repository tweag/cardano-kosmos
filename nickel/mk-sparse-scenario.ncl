fun node_count =>
let base = import "./scenarios/vanilla.ncl" in
let spo_count = std.array.fold_left
  (fun total group => total + (if group.role == 'spo then group.count else 0)) 0 base.topology.groups in
base & {
  name | force = "sparse%{node_count}",
  description | force = "%{node_count} nodes: same six SPOs and stake, four peers each",
  topology.groups | force = std.array.map
    (fun group => if group.role == 'relay then group & {count | force = node_count - spo_count} else group)
    base.topology.groups,
  topology.connections | force = std.array.map
    (fun node => std.array.filter
      (fun peer => let distance = if peer > node then peer - node else node - peer in
        distance == 1 || distance == 3 || distance == node_count - 3 || distance == node_count - 1)
      (std.array.range 1 (node_count + 1)))
    (std.array.range 1 (node_count + 1)),
}
