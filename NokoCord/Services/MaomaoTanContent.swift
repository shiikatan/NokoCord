import Foundation
import Darwin

/// Compares Maomao's immutable Tan payload without serializing or hashing it.
/// Swift string equality accepts canonical Unicode equivalents; source code
/// and the existing integrity digest require the original UTF-8 bytes instead.
enum MaomaoTanContent {
    static func matches(_ lhs: TanPackage, _ rhs: TanPackage) -> Bool {
        guard lhs == rhs else { return false }
        let a = lhs.manifest, b = rhs.manifest
        return bytesMatch(lhs.javascript, rhs.javascript)
            && bytesMatch(lhs.css, rhs.css)
            && bytesMatch(lhs.origin, rhs.origin)
            && bytesMatch(a.id, b.id)
            && bytesMatch(a.name, b.name)
            && bytesMatch(a.version, b.version)
            && bytesMatch(a.description, b.description)
            && zip(a.authors, b.authors).allSatisfy { bytesMatch($0, $1) }
            && bytesMatch(a.entry, b.entry)
            && bytesMatch(a.stylesheet, b.stylesheet)
            && bytesMatch(a.source, b.source)
            && bytesMatch(a.license, b.license)
    }

    private static func bytesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(a), .some(b)): return bytesMatch(a, b)
        case (.none, .none): return true
        default: return false
        }
    }

    private static func bytesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let contiguousMatch: Bool? = lhs.utf8.withContiguousStorageIfAvailable { a in
            rhs.utf8.withContiguousStorageIfAvailable { b in
                guard a.count == b.count else { return false }
                return a.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
            }
        } ?? nil
        return contiguousMatch ?? lhs.utf8.elementsEqual(rhs.utf8)
    }
}
