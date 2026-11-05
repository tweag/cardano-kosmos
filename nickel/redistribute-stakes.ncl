let { substringEnd, .. } = import "./prelude.ncl" in
let { filter, map, fold_left, length, flatten, map_with_index, .. } = std.array in
let { Scenario, Node, .. } = import "./schemas/scenario.ncl" in
let { InputParams, TestnetConfig, .. } = import "./schemas/testnet.ncl" in
let InitialFunds = { data | { _ | Number } } in
let PoolsIdxsMap = { _ | Number } in
let
  mkPoolsFunds = fun fundsPerPool pools_indices extraConfig => 
    std.record.fields extraConfig.initialFunds.data
    |> filter (fun key => std.string.length key == 114) # base address: 1 + 28 + 28 bytes, hex-encoded
    |> map (fun hex => {
      baseAddressHex = hex,
      stakeCredHash = substringEnd 56 hex, # the last 56 symbols is stake credential hash
      poolId = extraConfig.stakeCredentials.data."%{stakeCredHash}",
      poolIndex = pools_indices."%{poolId}",
      funds = std.record.get "%{poolIndex}" fundsPerPool,
    })
    |> fold_left (fun acc pool => acc & {
      "%{pool.baseAddressHex}" | force = pool.funds,
    }) {}
in
let
  mkFundsPerPool = fun availableFunds nodes =>
    nodes
    |> filter (fun n => n.role == 'spo)
    |> map_with_index (fun i n =>
        {
          field = "%{i + 1}",
          value = std.number.floor (availableFunds * n.stake),
        }
      )
    |> std.record.from_array,
in
let
  redistributeStakes = fun input =>
    let extraConfig = input.genesis.extraConfig in
    let initialFunds = extraConfig.initialFunds in
    let totalInitialFundsSupply = fold_left (fun acc p => acc + p.value) 0 (std.record.to_array initialFunds.data) in
    let halfOfTotal = totalInitialFundsSupply / 2 in
    let fundsPerPool = mkFundsPerPool halfOfTotal input.nodes in
    let poolsFunds = mkPoolsFunds fundsPerPool input.pools_indices extraConfig in
    { data = initialFunds.data & poolsFunds }
in
let
  mkInitialFunds | Scenario -> Dyn -> PoolsIdxsMap -> InitialFunds =
    fun s shelleyGenesis poolsIdxsMap =>
      redistributeStakes {
        nodes = s.topology.nodes,
        pools_indices = poolsIdxsMap,
        genesis = shelleyGenesis,
      }
in mkInitialFunds 

