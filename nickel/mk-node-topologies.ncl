fun ip scenario proxy_ports_base nodes_ports =>
  let { map, zip_with, map_with_index, fold_left, flatten, filter, .. } = std.array in
  let { for_each, .. } = import "prelude.ncl" in
  let
    mk_access_points = fun links nodes_map =>
      std.record.fields nodes_map
      |> map
        (fun node_name => {
          field = node_name,
          value =
            links
            |> filter (fun l => l.from == node_name)
            |> map (fun link => 
              let dest_node = std.record.get link.to nodes_map in
              { address = ip, port = dest_node.proxy_port }
            )
          }
        )
      |> std.record.from_array
  in
  let
    mk_node_topology = fun access_points =>
      {
        bootstrapPeers = null,
        localRoots = [
          {
            accessPoints = access_points,
            advertise = false,
            behindFirewall = false,
            diffusionMode = "InitiatorAndResponder",
            hotValency = 7,
            trustable = true,
            warmValency = 7,
          }
        ],
        publicRoots = [
          {
            accessPoints = [],
            advertise = false,
          }
        ],
        useLedgerAfterSlot = -1,
      }
  in
  let indexed_nodes = map_with_index (fun i n => {idx = i, node = n, proxy_port = proxy_ports_base + 1 + i}) scenario.topology.nodes in
  let nodes_with_ports = zip_with (fun n p => n & { port = p } ) indexed_nodes nodes_ports in
  let nodes_map = nodes_with_ports |> map (fun n => { field = n.node.name, value = n }) |> std.record.from_array in
  let access_points = mk_access_points scenario.topology.links nodes_map in
{
  nodes = nodes_with_ports,
  node_topologies = map (fun n => mk_node_topology (std.record.get n.node.name access_points)) nodes_with_ports,
}
