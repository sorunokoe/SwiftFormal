let shift = Int(CommandLine.arguments[1])!
let n = 1 << shift
let a = Array(repeating: 7 as Int, count: n)
print("made", a.count)
