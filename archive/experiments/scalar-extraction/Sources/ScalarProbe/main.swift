import Foundation
import ScalarExtraction

private struct Request: Decodable {
    let symbol: String
    let inputs: [[String]]
}

private struct Answer: Encodable {
    let inputs: [String]
    let status: String
    var value: String?
    var location: SourceLocation?
}

private struct FunctionResult: Encodable {
    let symbol: String
    let status: String
    var detail: String?
    var parameters: Int?
    var blocks: Int?
    var instructions: Int?
    var answers: [Answer]?
}

private struct Response: Encodable {
    let version = "0.0.2"
    let reportSHA256: String
    let silSHA256: String
    let results: [FunctionResult]
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
        throw ExtractionError.invalidArtifact(
            "Usage: scalar-probe REPORT.json FIXTURES_DIRECTORY REQUESTS.json"
        )
    }
    let collection = try CollectedSIL.load(
        reportURL: URL(fileURLWithPath: CommandLine.arguments[1]),
        fixturesURL: URL(fileURLWithPath: CommandLine.arguments[2])
    )
    let requests = try JSONDecoder().decode(
        [Request].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    )
    guard !requests.isEmpty else {
        throw ExtractionError.invalidArtifact("At least one requested function is required")
    }
    var results: [FunctionResult] = []
    var exitCode: Int32 = 0
    for request in requests {
        do {
            let function = try SILReader.extract(from: collection.text, symbol: request.symbol)
            let answers = try request.inputs.map { inputs in
                let arguments = try inputs.map { text in
                    guard let value = Int64(text) else {
                        throw ExtractionError.invalidArtifact("Invalid Int64 input: \(text)")
                    }
                    return value
                }
                switch try function.evaluate(arguments: arguments) {
                case .returned(let value):
                    return Answer(inputs: inputs, status: "RETURNED", value: String(value))
                case .arithmeticTrap(let location):
                    return Answer(inputs: inputs, status: "ARITHMETIC TRAP", location: location)
                }
            }
            results.append(
                FunctionResult(
                    symbol: request.symbol, status: "EXTRACTED",
                    parameters: function.parameterCount,
                    blocks: function.blockCount, instructions: function.instructionCount,
                    answers: answers
                ))
        } catch let error as ExtractionError {
            let status: String
            switch error {
            case .unsupported:
                status = "UNSUPPORTED"
                if exitCode == 0 { exitCode = 2 }
            case .invalidArtifact:
                status = "INVALID ARTIFACT"
                exitCode = 1
            }
            results.append(
                FunctionResult(symbol: request.symbol, status: status, detail: error.description))
        }
    }
    try collection.validateUnchanged()
    try emit(
        Response(
            reportSHA256: collection.reportSHA256, silSHA256: collection.silSHA256, results: results
        ))
    exit(exitCode)
} catch let error as ExtractionError {
    try emit(Failure(status: "INVALID ARTIFACT", detail: error.description))
    exit(1)
} catch {
    try emit(Failure(status: "TOOL ERROR", detail: String(describing: error)))
    exit(3)
}
