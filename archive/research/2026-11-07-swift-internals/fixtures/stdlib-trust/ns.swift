import Foundation
final class Huge: NSString {
    override var length: Int { 1 << 62 }
    override func character(at index: Int) -> unichar { 65 }
    override func copy(with zone: NSZone? = nil) -> Any { self }
}
let s: String = Huge() as String
print("utf16.count =", s.utf16.count, " isEmpty =", s.isEmpty)
print("crlf count =", "\r\n".count, " utf8 =", "\r\n".utf8.count)
print("e+acute ==", "e\u{301}" == "\u{e9}", "utf8:", "e\u{301}".utf8.count, "\u{e9}".utf8.count)
let ri1 = "\u{1F1FA}", ri3 = "\u{1F1F8}\u{1F1FA}\u{1F1F8}"
print("RI counts", ri1.count, ri3.count, (ri1 + ri3).count)
print("lowercased empty?", "".lowercased().isEmpty, "\u{130}".lowercased().count, "\u{130}".lowercased().utf8.count)
