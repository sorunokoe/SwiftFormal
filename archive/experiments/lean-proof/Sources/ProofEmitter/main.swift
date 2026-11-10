import CryptoKit
import Foundation
import LeanProof
import ScalarExtraction

private struct Bundle: Encodable {
    let schemaVersion = 1
    let version = "0.0.3"
    let reportSHA256: String
    let silSHA256: String
    let contractSHA256: String
    let proof: GeneratedProof
}

private struct Failure: Encodable {
    let status: String
    let detail: String
}

private func emit(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw ProofError.invalidContract(
            "Usage: proof-emitter COLLECTION.json FIXTURES_DIRECTORY CONTRACT.json")
    }
    let collection = try CollectedSIL.load(
        reportURL: URL(fileURLWithPath: CommandLine.arguments[1]),
        fixturesURL: URL(fileURLWithPath: CommandLine.arguments[2])
    )
    let contractURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let contractData = try Data(contentsOf: contractURL)
    let contract = try ProofContract.decode(contractData)
    let function = try SILReader.extract(from: collection.text, symbol: contract.symbol)
    let proof = try LeanEmitter.generate(for: function, contract: contract)
    try collection.validateUnchanged()
    guard try Data(contentsOf: contractURL) == contractData else {
        throw ExtractionError.invalidArtifact("Contract changed during generation")
    }
    try emit(
        Bundle(
            reportSHA256: collection.reportSHA256, silSHA256: collection.silSHA256,
            contractSHA256: SHA256.hash(data: contractData).map { String(format: "%02x", $0) }
                .joined(),
            proof: proof
        ))
} catch let error as ExtractionError {
    let status =
        switch error {
        case .unsupported: "UNSUPPORTED"
        case .invalidArtifact: "INVALID ARTIFACT"
        }
    try emit(Failure(status: status, detail: error.description))
    exit(1)
} catch let error as ProofError {
    let status =
        switch error {
        case .unsupported: "UNSUPPORTED"
        case .invalidContract: "INVALID CONTRACT"
        }
    try emit(Failure(status: status, detail: error.description))
    exit(1)
} catch {
    try emit(Failure(status: "TOOL ERROR", detail: String(describing: error)))
    exit(1)
}
