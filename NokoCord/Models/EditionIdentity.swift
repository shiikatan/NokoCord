import Foundation

/// Public edition metadata comes from the app bundle, which is populated by
/// Config/Edition.xcconfig in each edition branch. The private foundation has
/// no public edition identity.
struct EditionIdentity: Equatable {
    let id: String
    let name: String
    let publicVersion: String
    let maintainer: String

    static func load(from bundle: Bundle) -> EditionIdentity? {
        guard let values = bundle.infoDictionary,
              let id = nonempty(values["NokoEditionID"]),
              let name = nonempty(values["NokoEditionName"]),
              let version = nonempty(values["NokoPublicVersion"]),
              let maintainer = nonempty(values["NokoMaintainer"]) else { return nil }
        return EditionIdentity(id: id, name: name, publicVersion: version, maintainer: maintainer)
    }

    static var current: EditionIdentity? { load(from: .main) }

    private static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
