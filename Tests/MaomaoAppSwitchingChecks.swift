import Foundation
import JavaScriptCore
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let encoded = try JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed])
let literal = String(data: encoded, encoding: .utf8)!
let context = JSContext()!
context.exceptionHandler = { _, error in fputs("Script error: \(error?.toString() ?? "unknown")\n", stderr) }
guard context.evaluateScript("new Function(\(literal))") != nil, context.exception == nil else { exit(1) }
print("PASS logo switcher JavaScript parses in JavaScriptCore")

for origin in ["https://example.org", "https://discord.com.evil.invalid"] {
    let guarded = JSContext()!
    guarded.evaluateScript("var window = {}; window.top = window; var location = {origin: '\(origin)'}; (new Function(\(literal)))();")
    guard guarded.exception == nil else { fatalError("Foreign origin touched the DOM") }
}
let frame = JSContext()!
frame.evaluateScript("var window = {top: {}}; var location = {origin: 'https://discord.com'}; (new Function(\(literal)))();")
guard frame.exception == nil else { fatalError("Child frame touched the DOM") }
print("PASS switcher refuses foreign origins and child frames before DOM work")
