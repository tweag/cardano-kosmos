let { map, zip_with, map_with_index, fold_left, .. } = std.array in
let { for_each, .. } = import "prelude.ncl" in
let
  mk_listeners = fun ip topology proxy_ports_base =>
    let mk_listener = fun i n => {
      "@type" = "type.googleapis.com/envoy.config.listener.v3.Listener",
      name = n.name ++ "_listener",
      address = {
        socket_address = {
          address = ip,
          port_value = i + 1 + proxy_ports_base,
        },
      },
      drain_type = "MODIFY_ONLY",
      filter_chains = {
        filters = [{
          name = "envoy.filters.network.tcp_proxy",
          typed_config = {
            "@type" = "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
            stat_prefix = n.name ++ "_tcp",
            cluster = n.name ++ "_outbound",
            max_downstream_connection_duration = "1s",
          }
        }],
      },
    }
    in map_with_index mk_listener topology.nodes
in
let
  mk_clusters = fun ip topology proxy_ports_base nodes_ports =>
    let mk_endpoint = fun name port nodes_map acc link => 
      let new_item = if name == link.from
        then
          let node_port = std.record.get link.to nodes_map 
          in [{
            endpoint = {
              address = {
                socket_address = {
                  address = ip,
                  port_value = node_port,
                },
              },
            }
          }]
        else []
      in acc @ new_item,
    in
    let mk_cluster = fun nodes n => 
      let nodes_map = nodes |> map (fun n => { field = n.node.name, value = n.port }) |> std.record.from_array
      in {
      "@type" = "type.googleapis.com/envoy.config.cluster.v3.Cluster",
      name = n.node.name ++ "_outbound",
      connect_timeout = "0.25s",
      type = "STATIC",
      lb_policy = "ROUND_ROBIN",
      load_assignment = {
        cluster_name = n.node.name ++ "_outbound",
        endpoints = {
          lb_endpoints = fold_left (mk_endpoint n.node.name n.port nodes_map) [] topology.links,
        },
      },
    }
    in
    let indexed_nodes = map_with_index (fun i n => {idx = i, node = n, proxy_port = proxy_ports_base + 1 + i}) topology.nodes in
    let nodes = zip_with (fun n p => n & { port = p } ) indexed_nodes nodes_ports
    in map (mk_cluster nodes) nodes
in
fun directory ip port proxy_ports_base scenario nodes_ports =>
{
  main = {
    node = {
      cluster = "testnet",
      id = "testnet",
    },

    admin = {
      address = {
        socket_address = {
          address = ip,
          port_value = port,
        },
      },
    },

    layered_runtime = {
      layers = [
        {
          name = "static_layer_0",
          static_layer = {},
        },
        { name = "admin_layer_0",
          admin_layer = {}
        }
      ],
    },

    dynamic_resources = {
      cds_config = { path = "%{directory}/cds.json" },
      lds_config = { path = "%{directory}/lds.json" },
    },
  },
  clusters =  {
    resources = mk_clusters ip scenario.topology proxy_ports_base nodes_ports
  },
  listeners = {
    resources = mk_listeners ip scenario.topology proxy_ports_base
  },
}
