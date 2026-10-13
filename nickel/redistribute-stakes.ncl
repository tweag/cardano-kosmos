let { takeEnd, .. } = import "./prelude.ncl" in
let { filter, map, fold_left, length, flatten, .. } = std.array in
let { Scenario, Group, groupsWithIndices, .. } = import "./schemas/scenario.ncl" in
let { InputParams, TestnetConfig, .. } = import "./schemas/testnet.ncl" in
let InitialFunds = { data | { _ | Number } } in
let PoolsIdxsMap = { _ | Number } in
let
  mkPoolsFunds = fun fundsPerPool pools_indices extraConfig => 
    std.record.fields extraConfig.initialFunds.data
    |> filter (fun key => std.string.length key == 114)
    |> map (fun hex => {
      baseAddressHex = hex,
      stakeCredHash = takeEnd 56 hex,
      poolId = extraConfig.stakeCredentials.data."%{stakeCredHash}",
      poolIndex = pools_indices."%{poolId}",
      funds = std.record.get "%{poolIndex}" fundsPerPool,
    })
    |> fold_left (fun acc pool => acc & {
      "%{pool.baseAddressHex}" | force = pool.funds,
    }) {}
in
let
  mkFundsPerPool = fun availableFunds groups =>
    groups
    |> map (fun g =>
      let numOfSposInGroup = length g.indices
      in g.indices
      |> map (fun i =>
        {
          field = "%{i}",
          value = availableFunds * g.group.stake / numOfSposInGroup,
        }
      )
    )
    |> flatten
    |> std.record.from_array
in
let
  redistributeStakes = fun input =>
    let extraConfig = input.genesis.extraConfig in
    let initialFunds = extraConfig.initialFunds in
    let totalInitialFundsSupply = fold_left (fun acc p => acc + p.value) 0 (std.record.to_array initialFunds.data) in
    let halfOfTotal = totalInitialFundsSupply / 2 in
    let fundsPerPool = mkFundsPerPool halfOfTotal input.groups in
    let poolsFunds = mkPoolsFunds fundsPerPool input.pools_indices extraConfig in
    { data = initialFunds.data & poolsFunds }
in
let
  mkInitialFunds | Scenario -> Dyn -> PoolsIdxsMap -> InitialFunds =
    fun s shelleyGenesis poolsIdxsMap =>
      redistributeStakes {
        groups = groupsWithIndices s.topology.groups,
        pools_indices = poolsIdxsMap,
        genesis = shelleyGenesis,
      }
in mkInitialFunds 

