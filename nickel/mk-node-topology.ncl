fun ip node_ports_base exclude_idx num =>
(import "./mk-peer-topology.ncl") ip node_ports_base
  (std.array.filter (fun peer => peer != exclude_idx) (std.array.range 1 (num + 1)))
