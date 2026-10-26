fun ip node_ports_base exclude_idx num =>
let access_points = std.array.fold_left
  (fun acc p =>
    if p == exclude_idx 
    # excluding this idx
    then acc
    else acc @ [ { address = ip, port = node_ports_base + p } ]
  )
  [] (std.array.range 1 (num + 1)) 
in
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
