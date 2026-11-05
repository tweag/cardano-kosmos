fun directory ip port scenario nodes_with_ports =>
  let { map, zip_with, map_with_index, fold_left, flatten, filter, .. } = std.array in
  let { for_each, .. } = import "prelude.ncl" in
  let
    nodes_map = nodes_with_ports |> map (fun n => { field = n.node.name, value = n }) |> std.record.from_array
  in
  let 
    mk_listener = fun i n => {
      "@type" = "type.googleapis.com/envoy.config.listener.v3.Listener",
      name = n.node.name ++ "_listener",
      address = {
        socket_address = {
          address = ip,
          port_value = n.proxy_port,
        },
      },
      drain_type = "MODIFY_ONLY",
      filter_chains = {
        filters = [{
          name = "envoy.filters.network.tcp_proxy",
          typed_config = {
            "@type" = "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
            stat_prefix = n.node.name ++ "_tcp",
            cluster = n.node.name ++ "_outbound",
            max_downstream_connection_duration = "1s",
          }
        }],
      },
    },
    mk_clusters = fun topology =>
      let mk_endpoint = fun name port acc link => 
        let new_item = if name == link.from
          then
            let dest_node = std.record.get link.to nodes_map 
            in [{
              endpoint = {
                address = {
                  socket_address = {
                    address = ip,
                    port_value = dest_node.port,
                  },
                },
              }
            }]
          else []
        in acc @ new_item,
      in
      let
        mk_cluster = fun n => {
          "@type" = "type.googleapis.com/envoy.config.cluster.v3.Cluster",
          name = n.node.name ++ "_outbound",
          connect_timeout = "0.25s",
          type = "STATIC",
          lb_policy = "ROUND_ROBIN",
          load_assignment = {
            cluster_name = n.node.name ++ "_outbound",
            endpoints = {
              lb_endpoints = fold_left (mk_endpoint n.node.name n.port) [] topology.links,
            },
          },
        }
      in map mk_cluster nodes_with_ports,
  in
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
      resources = mk_clusters scenario.topology,
    },
    listeners = {
      resources = map_with_index mk_listener nodes_with_ports,
    },
  }
