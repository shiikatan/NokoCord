import Foundation
import JavaScriptCore
import CryptoKit

// One bounded request, one reply, then exit. No plugin source is executed.
func run() throws {
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        input.append(chunk)
        guard input.count <= 16 * 1024 * 1024 else { throw Failure.invalid }
    }
    guard let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let files = request["files"] as? [String: String], files.count <= 128,
          files.values.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024,
          let context = JSContext() else { throw Failure.invalid }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let resource = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/TanTranslatorRuntime.js")
    let runtime = try String(contentsOf: resource, encoding: .utf8)
    var failed = false
    context.exceptionHandler = { _, _ in failed = true }
    let hash: @convention(block) (String) -> String = { value in
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    let size: @convention(block) (String) -> Int = { $0.utf8.count }
    context.setObject(hash, forKeyedSubscript: "nokoSHA256" as NSString)
    context.setObject(size, forKeyedSubscript: "nokoUTF8Size" as NSString)
    context.evaluateScript(runtime)
    guard !failed, let function = context.objectForKeyedSubscript("nokoTranslate") else { throw Failure.invalid }
    guard let value = function.call(withArguments: [request]), !failed,
          let result = value.toDictionary() else { throw Failure.invalid }
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    guard output.count <= 16 * 1024 * 1024 else { throw Failure.invalid }
    try FileHandle.standardOutput.write(contentsOf: output)
}
enum Failure: Error { case invalid }
do { try autoreleasepool { try run() } }
catch {
    // No source text, native errors, paths or JavaScript exception payloads.
    try? FileHandle.standardOutput.write(contentsOf: Data("{\"error\":\"Conversion could not be completed\"}".utf8))
    exit(1)
}
