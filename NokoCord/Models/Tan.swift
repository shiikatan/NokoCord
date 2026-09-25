import Foundation
import CryptoKit
import Darwin

enum TanTarget: String, Codable, CaseIterable { case css, isolated, page }
enum TanCapability: String, Codable { case appearanceRead = "appearance.read" }

struct TanManifest: Codable, Equatable, Identifiable {
    var schemaVersion = 1
    let id: String
    let name: String
    let version: String
    let description: String
    let authors: [String]
    let target: TanTarget
    var entry: String?
    var stylesheet: String?
    var capabilities: [TanCapability] = []
    var requiresReload = false
    var source: String?
    var license: String?

    func validate() throws {
        func safeDisplayText(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard schemaVersion == 1 else { throw TanError.invalid("Unsupported manifest version") }
        guard id.range(of: "^[a-z0-9][a-z0-9.-]{2,79}$", options: .regularExpression) != nil,
              !id.contains(".."), !id.hasSuffix(".") else { throw TanError.invalid("Invalid Tan identifier") }
        guard safeDisplayText(name), name.count <= 80, description.count <= 1000,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              !authors.isEmpty, authors.count <= 8,
              authors.allSatisfy({ safeDisplayText($0) && $0.count <= 100 }) else {
            throw TanError.invalid("Invalid Tan metadata")
        }
        for file in [entry, stylesheet].compactMap({ $0 }) {
            guard file.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$", options: .regularExpression) != nil,
                  !file.contains("..") else { throw TanError.invalid("Tan files must be local filenames") }
        }
        guard target == .css ? (entry == nil && stylesheet?.hasSuffix(".css") == true) : entry?.hasSuffix(".js") == true else {
            throw TanError.invalid("Missing Tan entry file")
        }
        if let stylesheet, !stylesheet.hasSuffix(".css") { throw TanError.invalid("Stylesheets must be CSS") }
        guard Set(capabilities).count == capabilities.count,
              target == .isolated || capabilities.isEmpty else { throw TanError.invalid("Native capabilities require an isolated Tan") }
        if let source {
            guard let url = URL(string: source), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil else { throw TanError.invalid("Invalid Tan source URL") }
        }
    }
}

struct TanPackage: Codable, Equatable, Identifiable {
    let manifest: TanManifest
    let javascript: String?
    let css: String?
    let origin: String
    var id: String { manifest.id }
    var contentHash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        try manifest.validate()
        guard origin.count <= 200, (javascript?.utf8.count ?? 0) + (css?.utf8.count ?? 0) <= 512 * 1024,
              manifest.target == .css ? javascript == nil : javascript != nil,
              manifest.stylesheet == nil || css != nil else { throw TanError.invalid("Invalid or oversized Tan content") }
    }
    static func load(folder: URL) throws -> TanPackage {
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw TanError.invalid("Invalid Tan package folder") }
        defer { close(directory) }
        func read(_ filename: String, limit: Int) throws -> Data {
            let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw TanError.invalid("Missing or invalid Tan file") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size <= limit else {
                throw TanError.invalid("Invalid or oversized Tan file")
            }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(65536, limit - data.count + 1)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= limit else { throw TanError.invalid("Oversized Tan file") }
            }
            return data
        }
        let manifest = try JSONDecoder().decode(TanManifest.self, from: read("manifest.json", limit: 16 * 1024))
        try manifest.validate()
        func content(_ filename: String?) throws -> String? {
            guard let filename else { return nil }
            guard let text = String(data: try read(filename, limit: 512 * 1024), encoding: .utf8) else { throw TanError.invalid("Tan source must be UTF-8") }
            return text
        }
        let result = TanPackage(manifest: manifest, javascript: try content(manifest.entry), css: try content(manifest.stylesheet), origin: "Local package")
        try result.validate(); return result
    }
}

enum TanError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct TanDiagnostic: Identifiable {
    let id = UUID()
    let tanID: String
    let event: Event
    let date = Date()
    enum Event: String { case started, stopped, failed, rejected }
}

struct TanBridgeRequest: Decodable {
    let type: String
    let capability: String?
    let state: String?
    static func parse(_ body: [String: Any]) -> TanBridgeRequest? {
        guard let type = body["type"] as? String else { return nil }
        if type == "status", Set(body.keys) == ["type", "state"],
           let state = body["state"] as? String, ["started", "stopped", "failed"].contains(state) {
            return TanBridgeRequest(type: type, capability: nil, state: state)
        }
        if type == "capability", Set(body.keys) == ["type", "capability"],
           let capability = body["capability"] as? String, capability == TanCapability.appearanceRead.rawValue {
            return TanBridgeRequest(type: type, capability: capability, state: nil)
        }
        return nil
    }
    func permits(_ manifest: TanManifest) -> Bool {
        guard manifest.target == .isolated else { return false }
        return type == "capability" && capability == TanCapability.appearanceRead.rawValue && manifest.capabilities.contains(.appearanceRead)
    }
}

extension TanPackage {
    static let originals: [TanPackage] = [
        TanPackage(manifest: TanManifest(id: "noko.clear-focus", name: "Clear Focus", version: "1.2.0", description: "Make keyboard focus clear while preserving Discord’s existing focus treatment.", authors: ["shiikatan"], target: .isolated, entry: "main.js", stylesheet: "style.css"), javascript: #"""
NokoTan.register({
  start(api) {
    let marked = null, frame = null;
    const clear = () => { marked?.deref()?.removeAttribute('data-noko-focus'); marked = null; if (frame !== null) cancelAnimationFrame(frame); frame = null; };
    const visible = style => (style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 1 && style.outlineColor !== 'transparent' && style.outlineColor !== 'rgba(0, 0, 0, 0)') || style.boxShadow !== 'none';
    const focus = event => {
      clear();
      const reference = new WeakRef(event.target);
      frame = requestAnimationFrame(() => {
        frame = null;
        const target = reference.deref();
        if (!(target instanceof Element) || !target.isConnected || !target.matches(':focus-visible')) return;
        // Inspect styling only, never text, inputs, credentials or session data.
        let element = target;
        for (let depth = 0; element && depth < 3; depth++, element = element.parentElement) {
          if (visible(getComputedStyle(element)) || visible(getComputedStyle(element, '::before')) || visible(getComputedStyle(element, '::after'))) return;
        }
        target.setAttribute('data-noko-focus', ''); marked = reference;
      });
    };
    api.listen(document, 'focusin', focus, true);
    api.listen(document, 'focusout', clear, true);
    api.onCleanup(clear);
  }
});
"""#, css: "[data-noko-focus]:focus-visible { outline: 2px solid #5b9dff !important; outline-offset: 2px !important; }", origin: "Noko-Tan"),
        TanPackage(manifest: TanManifest(id: "noko.scroll-tools", name: "Scroll Tools", version: "1.1.0", description: "Move through the active panel, from loaded history to the newest content.", authors: ["shiikatan"], target: .isolated, entry: "main.js"), javascript: #"""
NokoTan.register({
  start(api) {
    let active = null;
    const bar = document.createElement('div');
    bar.setAttribute('data-noko-scroll-tools', '');
    bar.setAttribute('role', 'toolbar'); bar.setAttribute('aria-label', 'Noko scroll tools');
    bar.style.cssText = 'position:fixed;bottom:24px;right:24px;z-index:2147483000;display:flex;gap:2px;padding:4px;border:1px solid #ffffff28;border-radius:14px;background:#25252bf5;color:#f5eee4;box-shadow:0 3px 12px #0003;font:12px system-ui';
    const eligible = element => element instanceof Element && !bar.contains(element) && element.scrollHeight > element.clientHeight + 4 && /auto|scroll/.test(getComputedStyle(element).overflowY);
    const remember = element => { if (eligible(element)) active = new WeakRef(element); };
    const locate = event => {
      let element = event.target instanceof Element ? event.target : null;
      while (element && element !== document.documentElement) {
        if (eligible(element)) { remember(element); return; }
        element = element.parentElement;
      }
    };
    api.listen(document, 'scroll', event => remember(event.target), {capture:true, passive:true});
    api.listen(document, 'wheel', locate, {capture:true, passive:true});
    api.listen(document, 'focusin', locate, true);
    api.listen(document, 'pointerdown', event => { if (!bar.contains(event.target)) locate(event); }, true);
    for (const [label, glyph, end] of [['Earlier', '↑', false], ['Newest', '↓', true]]) {
      const button = document.createElement('button');
      button.textContent = glyph + ' ' + label;
      button.title = end ? 'Go to the end of the active panel' : 'Go to the start of loaded content. Discord may load earlier history; this is not an instant jump to the first message.';
      button.setAttribute('aria-label', button.title);
      button.style.cssText = 'color:inherit;background:transparent;border:0;padding:8px 11px;border-radius:10px;cursor:pointer;font:500 12px system-ui';
      api.listen(button, 'pointerenter', () => { button.style.background = '#ffffff14'; });
      api.listen(button, 'pointerleave', () => { button.style.background = 'transparent'; });
      api.listen(button, 'click', () => {
        const remembered = active?.deref();
        const target = remembered?.isConnected ? remembered : document.scrollingElement;
        target?.scrollTo({ top: end ? target.scrollHeight : 0, behavior: 'instant' });
      });
      bar.append(button);
    }
    api.mount(bar);
    return () => { active = null; };
  }
});
"""#, css: nil, origin: "Noko-Tan")
    ]
}

extension TanManifest {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, version, description, authors, target, entry, stylesheet, capabilities, requiresReload, source, license
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        authors = try c.decode([String].self, forKey: .authors)
        target = try c.decode(TanTarget.self, forKey: .target)
        entry = try c.decodeIfPresent(String.self, forKey: .entry)
        stylesheet = try c.decodeIfPresent(String.self, forKey: .stylesheet)
        capabilities = try c.decodeIfPresent([TanCapability].self, forKey: .capabilities) ?? []
        requiresReload = try c.decodeIfPresent(Bool.self, forKey: .requiresReload) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
        license = try c.decodeIfPresent(String.self, forKey: .license)
    }
}
