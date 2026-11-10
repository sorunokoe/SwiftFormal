import Foundation
@testable import SwiftFormalTesting
import Testing

// `BehaviorLock.mask` looks at the bytes before it runs the scalar walk and the UUID regex. The result must equal
// the plain version on every kind of text, including text that has only part of what the slow path looks for.

private func plainMask(_ text: String) -> String {
    var result = ""
    var scalars = text.unicodeScalars[...]
    while let first = scalars.first {
        if first == "0", scalars.dropFirst().first == "x" {
            let digits = scalars.dropFirst(2).prefix(while: { $0.properties.isASCIIHexDigit })
            if digits.count >= 6 {
                result += "0x*"
                scalars = scalars.dropFirst(2 + digits.count)
                continue
            }
        }
        result.unicodeScalars.append(first)
        scalars = scalars.dropFirst()
    }
    let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    return result.replacingOccurrences(of: pattern, with: "<uuid>", options: .regularExpression)
}

@Suite struct LockMaskTests {
    @Test(arguments: [
        "",
        "plain text",
        "Shot(carry: 212.5, spin: -2650)",
        "<Club: 0x000000012ab3c4d0>",
        "0x12 is short, 0xABCDEF is long",
        "0x",
        "x0x0x0x123456",
        "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        "id=e621e1f8-c36c-495a-93fc-0c247a3e6e5f at 0x0000600001234567",
        "a-b-c-d",
        "1-2-3-4-5 0xZZZZZZ",
        "café 0x00ff00ff00 ü-ü-ü-ü",
        "\u{30}\u{78}\u{1F600}123456",
    ])
    func maskEqualsThePlainVersion(text: String) {
        #expect(BehaviorLock.mask(text) == plainMask(text))
    }
}
