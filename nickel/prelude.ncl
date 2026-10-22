let export = {
  substringEnd = fun n str =>
    let len = std.string.length str in
    let start = if len < n then 0 else len - n in
    std.string.substring start len str,
  sum = fun items => std.array.fold_left (fun acc item => acc + item) 0 items,
  for_each = fun arr act => std.array.map act arr,
}
in export
