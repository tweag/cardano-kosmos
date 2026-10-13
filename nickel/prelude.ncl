let export = {
  takeEnd = fun n str =>
    let len = std.string.length str in
    let start = if len < n then 0 else len - n in
    std.string.substring start len str
}
in export
