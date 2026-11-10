# id, file, old, new, description
S0 = 'Sources/SFSemantics/S0.swift'
ENC = 'Sources/SFSIL/SILEncoder.swift'
PAR = 'Sources/SFSIL/SILParser.swift'
MUTANTS = [
 ('M01', S0, 'let bad = c.or(c.eq(b, c.constant(0, width: width)), c.and(isMin, minusOne))', 'let bad = c.or(c.eq(b, c.constant(0, width: width)), c.and(c.and(isMin, minusOne), c.falseLit))', 'encode sdiv/srem: INT_MIN / -1 no longer undefined'),
 ('M02', S0, 'case .shl: return ([c.shiftLeft(a, by: b)], c.shiftAmountOutOfRange(a, b))', 'case .shl: return ([c.shiftLeft(a, by: b)], none)', 'encode shl: oversize shift not undefined'),
 ('M03', S0, 'case .ugt: return ([flag(c.ult(b, a))], none)', 'case .ugt: return ([flag(c.ult(a, b))], none)', 'encode ugt: operands swapped'),
 ('M04', S0, 'case .sext: return ([c.signExtend(a, to: resultWidth)], none)', 'case .sext: return ([c.zeroExtend(a, to: resultWidth)], none)', 'encode sext as zext'),
 ('M05', S0, 'case .ssubOverflow: return ([c.subSigned(a, b), flag(c.signedSubOverflows(a, b))], none)', 'case .ssubOverflow: return ([c.subSigned(a, b), flag(c.signedAddOverflows(a, b))], none)', 'encode ssub overflow flag from add'),
 ('M06', S0, 'return ([op == .udiv ? q : r], c.eq(b, c.constant(0, width: width)))', 'return ([op == .udiv ? q : r], none)', 'encode udiv/urem: division by zero not undefined'),
 ('M07', S0, 'case .sle: return ([flag(c.sle(a, b))], none)', 'case .sle: return ([flag(c.slt(a, b))], none)', 'encode sle as slt (boundary)'),
 ('M08', S0, 'case .ashr: return b >= UInt64(width) ? .undefined : .values([UInt64(bitPattern: sa >> Int64(b)) & m])', 'case .ashr: return b >= UInt64(width) ? .undefined : .values([a >> b])', 'evaluate ashr as lshr (reference interpreter only)'),
 ('M09', S0, 'case .umulOverflow: return ([c.mul(a, b, narrowing: false), flag(c.unsignedMulOverflows(a, b))], none)', 'case .umulOverflow: return ([c.mul(a, b, narrowing: false), flag(c.signedMulOverflows(a, b))], none)', 'encode umul overflow flag signed'),
 ('M10', ENC, 'trap(-c.ult(try intArgument(call, 1), n), site: call.site + "Index out of range")\n                    try setOutResult(call) { fresh($0) }\n                case .first, .last:', 'trap(-c.ule(try intArgument(call, 1), n), site: call.site + "Index out of range")\n                    try setOutResult(call) { fresh($0) }\n                case .first, .last:', 'array subscript get: index == count accepted (off by one)'),
 ('M11', ENC, 'out.traps.append(TrapEvent(block: blockIndex, condition: c.and(at, result.trap), site: site))\n                live = c.and(live, -c.and(at, result.trap))', 'live = c.and(live, -c.and(at, result.trap))', 'callee traps dropped at call sites'),
 ('M12', PAR, '        let mask: UInt64 = w == 64 ? ~0 : (1 << UInt64(w)) - 1\n        return .literal(', '        let mask: UInt64 = w == 64 ? ~0 : (1 << UInt64(w - 1)) - 1\n        return .literal(', 'integer_literal mask drops the top bit'),
 ('M13', PAR, '            return value == "-1" || value == "1" ? String(line[..<eq.lowerBound]) : nil', '            return value == "-1" || value == "1" || value == "0" ? String(line[..<eq.lowerBound]) : nil', 'unconditional-failure detector also accepts a 0 literal'),
 ('M14', ENC, 'out.traps.append(TrapEvent(block: blockIndex, condition: c.and(live, v.bits[0]), site: id))\n                    live = c.and(live, -v.bits[0])', 'out.traps.append(TrapEvent(block: blockIndex, condition: c.and(live, v.bits[0]), site: id))', 'cond_fail no longer stops execution (later traps reachable after failure)'),
]
