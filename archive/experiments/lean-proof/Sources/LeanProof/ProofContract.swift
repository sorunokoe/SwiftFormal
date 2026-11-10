import Foundation

public enum ProofError: Error, CustomStringConvertible {
    case invalidContract(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .invalidContract(let detail): "INVALID CONTRACT: \(detail)"
        case .unsupported(let detail): "UNSUPPORTED: \(detail)"
        }
    }
}

public struct ProofContract: Sendable {
    public let symbol: String
    public let witness: [Int64]

    public static func decode(_ data: Data) throws -> ProofContract {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys) == ["schema_version", "symbol", "requires", "ensures", "witness"]
            else {
                throw ProofError.invalidContract("Unexpected contract fields")
            }
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard wire.schemaVersion == 1,
                wire.symbol == "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF",
                wire.requires == "nonnegative-int64-pair",
                wire.ensures == "exact-clamped-subtraction",
                wire.witness.count == 2
            else {
                throw ProofError.invalidContract(
                    "Only the declared clamped-discount preset is supported")
            }
            let witness = try wire.witness.map { text in
                guard let value = Int64(text) else {
                    throw ProofError.invalidContract("Witness is not an Int64")
                }
                return value
            }
            return ProofContract(symbol: wire.symbol, witness: witness)
        } catch let error as ProofError {
            throw error
        } catch {
            throw ProofError.invalidContract(String(describing: error))
        }
    }

    private struct Wire: Decodable {
        let schemaVersion: Int
        let symbol: String
        let requires: String
        let ensures: String
        let witness: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case symbol, requires, ensures, witness
        }
    }
}
