// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// A call chain over a call with no body (`BinaryTypeScanTests`): a caller's verdict rests on what its callees assumed.
// The chain is deeper than the encoder inlines, so `chainTop` is proved only with `--modular`, by a contract of the
// chain.

import Kit

/// Inlined: the callee's assumption is the caller's too.
func viaHelper(_ surface: Surface) -> Int32 { ordinalChain11(surface) }

func chainTop(_ surface: Surface) -> Int32 { ordinalChain0(surface) + 1 }

func ordinalChain0(_ surface: Surface) -> Int32 { ordinalChain1(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain06VerifyfMp_.swift", line: 1)
func ordinalChain0_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain1(_ surface: Surface) -> Int32 { ordinalChain2(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain16VerifyfMp_.swift", line: 1)
func ordinalChain1_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain2(_ surface: Surface) -> Int32 { ordinalChain3(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain26VerifyfMp_.swift", line: 1)
func ordinalChain2_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain3(_ surface: Surface) -> Int32 { ordinalChain4(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain36VerifyfMp_.swift", line: 1)
func ordinalChain3_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain4(_ surface: Surface) -> Int32 { ordinalChain5(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain46VerifyfMp_.swift", line: 1)
func ordinalChain4_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain5(_ surface: Surface) -> Int32 { ordinalChain6(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain56VerifyfMp_.swift", line: 1)
func ordinalChain5_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain6(_ surface: Surface) -> Int32 { ordinalChain7(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain66VerifyfMp_.swift", line: 1)
func ordinalChain6_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain7(_ surface: Surface) -> Int32 { ordinalChain8(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain76VerifyfMp_.swift", line: 1)
func ordinalChain7_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain8(_ surface: Surface) -> Int32 { ordinalChain9(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain86VerifyfMp_.swift", line: 1)
func ordinalChain8_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain9(_ surface: Surface) -> Int32 { ordinalChain10(surface) }
#sourceLocation(file: "@__swiftmacro_3App13ordinalChain96VerifyfMp_.swift", line: 1)
func ordinalChain9_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain10(_ surface: Surface) -> Int32 { ordinalChain11(surface) }
#sourceLocation(file: "@__swiftmacro_3App14ordinalChain106VerifyfMp_.swift", line: 1)
func ordinalChain10_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
func ordinalChain11(_ surface: Surface) -> Int32 { let o = surface.ordinal; return o < 0 ? 0 : (o > 100 ? 100 : o) }
#sourceLocation(file: "@__swiftmacro_3App14ordinalChain116VerifyfMp_.swift", line: 1)
func ordinalChain11_ensures(_ surface: Surface, _ r: Int32) -> Bool { r >= 0 && r <= 100 }
#sourceLocation()
