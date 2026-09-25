// Developer-only integration/performance probe. Never reads a Discord session.
import Foundation
import JavaScriptCore
import CryptoKit

func convert(runtime: String) throws -> [String: Any] {
    guard let context = JSContext() else { throw ProbeError.runtime }
    var failed = false
    context.exceptionHandler = { _, _ in failed = true }
    let hash: @convention(block) (String) -> String = { value in
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    let size: @convention(block) (String) -> Int = { $0.utf8.count }
    context.setObject(hash, forKeyedSubscript: "nokoSHA256" as NSString)
    context.setObject(size, forKeyedSubscript: "nokoUTF8Size" as NSString)
    context.evaluateScript(runtime)
    guard !failed else { throw ProbeError.runtime }
    let fixture = """
    import definePlugin, {StartAt} from '@utils/types';
    export default definePlugin({name:'Fixture',description:'Synthetic fixture',
      authors:[{name:'Fixture'}],startAt:StartAt.DOMContentLoaded,
      start(){document.body.setAttribute('data-fixture','yes')},
      stop(){document.body.removeAttribute('data-fixture')}});
    """
    let input: [String: Any] = ["files": ["index.ts": fixture, "LICENSE": "Synthetic fixture"], "id": "fixture.jsc"]
    guard let result = context.objectForKeyedSubscript("nokoTranslate")?.call(withArguments: [input]), !failed,
          let report = result.objectForKeyedSubscript("report")?.toDictionary() as? [String: Any],
          report["classification"] as? String == "Automatic",
          let script = result.objectForKeyedSubscript("outputs")?.objectForKeyedSubscript("main.js")?.toString(),
          script.contains("NokoTan.register") else { throw ProbeError.conversion }
    return ["classification": "Automatic", "outputBytes": script.utf8.count]
}
enum ProbeError: Error { case runtime, conversion }

guard CommandLine.arguments.count == 2 else { fatalError("Pass the generated runtime file") }
let runtime = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let started = Date()
for _ in 0..<20 {
    _ = try autoreleasepool { try convert(runtime: runtime) }
}
let result: [String: Any] = ["conversions": 20, "elapsedSeconds": Date().timeIntervalSince(started), "runtimeBytes": runtime.utf8.count]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
