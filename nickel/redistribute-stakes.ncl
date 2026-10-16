let { takeEnd, .. } = import "./prelude.ncl"
in
let { Scenario, Group, groupsWithIndices, .. } = import "./schemas/scenario.ncl"
in
let { InputParams, TestnetConfig, .. } = import "./schemas/testnet.ncl"
in
let InitialFunds = { data | { _ | Number } }
in
let PoolsIdxsMap = { _ | Number }
in
let
  mkPools = fun pools_indices extraConfig => 
    std.record.fields extraConfig.initialFunds.data
    |> std.array.filter (fun key => std.string.length key == 114)
    |> std.array.map (fun hex => {
      baseAddressHex = hex,
      stakeCredHash = takeEnd 56 hex,
      poolId = extraConfig.stakeCredentials.data."%{stakeCredHash}",
      poolIndex = pools_indices."%{poolId}",
    })
in
let
  mkGroups = fun groups =>
    groups
    |> std.array.map (fun g => {
      stake = g.group.stake,
      indices = g.indices,
    })
in
let
  redistributeStakes = fun input =>
    let extraConfig = input.genesis.extraConfig in
    let initialFunds = extraConfig.initialFunds in
    let pools = mkPools input.pools_indices extraConfig in
    let totalInitialFundsSupply = std.array.fold_left (fun acc p => acc + p.value) 0 (std.record.to_array initialFunds.data) in
    let totalStakeSum = std.array.fold_left (fun acc g => acc + g.group.stake) 0 input.groups in
    let relaysSum = totalInitialFundsSupply - totalStakeSum in
      std.trace (std.serialize 'Json [ totalInitialFundsSupply, totalStakeSum, relaysSum ]) (
        std.trace (std.serialize 'Json (mkGroups input.groups)) initialFunds),
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

