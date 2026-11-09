fun ip node_ports_base peers =>
{
  bootstrapPeers = null,
  localRoots = [{
    accessPoints = std.array.map (fun peer => {address = ip, port = node_ports_base + peer}) peers,
    advertise = false,
    behindFirewall = false,
    diffusionMode = "InitiatorAndResponder",
    hotValency = std.array.length peers,
    trustable = true,
    warmValency = std.array.length peers,
  }],
  publicRoots = [{accessPoints = [], advertise = false}],
  useLedgerAfterSlot = -1,
}
