import Foundation
import Darwin

enum ManualUpdateError: LocalizedError, Equatable {
    case unsupportedEdition
    case unsafePath(String)
    case invalidArchive(String)
    case invalidApplication(String)
    case versionRejected(currentVersion: String, currentBuild: String, candidateVersion: String, candidateBuild: String)
    case baselineUnsupported(currentVersion: String, currentBuild: String, candidateVersion: String, candidateBuild: String)
    case staleCandidate
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedEdition: return "Manual updates are available only for the Maomao edition."
        case .unsafePath(let detail): return "The update path is unsafe: \(detail)"
        case .invalidArchive(let detail): return "The update archive is invalid: \(detail)"
        case .invalidApplication(let detail): return "The application in the archive is invalid: \(detail)"
        case .versionRejected(let currentVersion, let currentBuild, let candidateVersion, let candidateBuild):
            return "This archive contains Maomao \(candidateVersion) (build \(candidateBuild)); the installed build is \(currentVersion) (build \(currentBuild)). Downgrades are not supported."
        case .baselineUnsupported(let currentVersion, let currentBuild, let candidateVersion, let candidateBuild):
            return "Maomao \(currentVersion) (build \(currentBuild)) is below the supported updater baseline. The archive contains \(candidateVersion) (build \(candidateBuild)); install the M1.3.0 build 3 checkpoint first."
        case .staleCandidate: return "The inspected update has changed. Inspect the archive again."
        case .unavailable(let detail): return detail
        }
    }
}

/// The one edition-specific data-path resolver shared by Tan storage and the
/// manual updater. It deliberately leaves the old shared NokoCord/Tans folder
/// outside Maomao's owned paths.
struct MaomaoDataPaths: Equatable, Sendable {
    static let bundleIdentifier = "com.shiikatan.nokocord.maomao"
    static let editionID = "maomao"

    let home: URL
    var applicationSupportRoot: URL {
        home.appendingPathComponent("Library/Application Support/NokoCord", isDirectory: true)
    }
    var editionRoot: URL {
        applicationSupportRoot.appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
    }
    var tanStorage: URL { editionRoot.appendingPathComponent("Tans", isDirectory: true) }
    var updateRoot: URL { editionRoot.appendingPathComponent("Updater", isDirectory: true) }
    var candidateRoot: URL { updateRoot.appendingPathComponent("Candidates", isDirectory: true) }
    var helperFailureResult: URL { updateRoot.appendingPathComponent("last-helper-failure.json") }
    var noLegacyTanImportMarker: URL { updateRoot.appendingPathComponent("no-legacy-tan-import") }
    var pendingUpdateTransaction: URL { updateRoot.appendingPathComponent("pending-update-transaction.json") }
    var pendingCleanReset: URL { updateRoot.appendingPathComponent("pending-clean-reset.json") }
    var legacySharedTanStorage: URL { applicationSupportRoot.appendingPathComponent("Tans", isDirectory: true) }
    var cacheRoot: URL {
        home.appendingPathComponent("Library/Caches/\(Self.bundleIdentifier)", isDirectory: true)
    }
    var preferencesPlist: URL {
        home.appendingPathComponent("Library/Preferences/\(Self.bundleIdentifier).plist")
    }
    var savedApplicationState: URL {
        home.appendingPathComponent("Library/Saved Application State/\(Self.bundleIdentifier).savedState", isDirectory: true)
    }

    init(home: URL? = nil) {
        let resolvedHome: URL
        if let home {
            resolvedHome = home
        } else {
            #if DEBUG
            if let testHome = ProcessInfo.processInfo.environment["NOKOCORD_UPDATER_TEST_HOME"],
               testHome.hasPrefix("/"), !testHome.contains("//"),
               !testHome.split(separator: "/").contains("."),
               !testHome.split(separator: "/").contains("..") {
                resolvedHome = URL(fileURLWithPath: testHome, isDirectory: true)
            } else {
                resolvedHome = FileManager.default.homeDirectoryForCurrentUser
            }
            #else
            resolvedHome = FileManager.default.homeDirectoryForCurrentUser
            #endif
        }
        // Preserve the caller's physical path spelling. In particular,
        // `/private/var/...` is the real temporary-data path on macOS while
        // Foundation's standardizedFileURL aliases it back through `/var`.
        self.home = URL(fileURLWithPath: resolvedHome.path, isDirectory: true)
    }

    static func current(bundle: Bundle = .main, home: URL? = nil) throws -> MaomaoDataPaths {
        guard bundle.bundleIdentifier == bundleIdentifier,
              (bundle.infoDictionary?["NokoEditionID"] as? String) == editionID else {
            throw ManualUpdateError.unsupportedEdition
        }
        return MaomaoDataPaths(home: home)
    }

    /// Rejects every existing symbolic-link component, including the leaf.
    /// Missing suffixes are allowed so callers can create a path one component
    /// at a time without following a pre-existing link.
    static func validateNoSymlinkComponents(at url: URL) throws {
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("//"),
              !path.split(separator: "/").contains("."), !path.split(separator: "/").contains("..") else {
            throw ManualUpdateError.unsafePath("path is not absolute and canonical")
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw ManualUpdateError.unsafePath("symbolic link at \(current.lastPathComponent)")
                }
            } else if errno != ENOENT {
                throw ManualUpdateError.unsafePath("could not inspect \(current.lastPathComponent)")
            }
        }
    }

    static func createPrivateDirectory(_ url: URL) throws {
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("//"),
              !path.split(separator: "/").contains("."), !path.split(separator: "/").contains("..") else {
            throw ManualUpdateError.unsafePath("non-canonical directory path")
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw ManualUpdateError.unsafePath("non-directory path component")
                }
            } else {
                guard errno == ENOENT, mkdir(current.path, 0o700) == 0 || errno == EEXIST else {
                    throw ManualUpdateError.unsafePath("could not create private directory")
                }
                guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw ManualUpdateError.unsafePath("directory changed while being created")
                }
            }
        }
        try validateNoSymlinkComponents(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}

struct ManualUpdateVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    init(_ value: String) throws {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard fields.count == 3,
              fields.allSatisfy({ field in !field.isEmpty && field.utf8.allSatisfy { (48...57).contains($0) } }),
              numbers.count == 3 else {
            throw ManualUpdateError.invalidApplication("invalid numeric marketing version")
        }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<3 where lhs.components[index] != rhs.components[index] {
            return lhs.components[index] < rhs.components[index]
        }
        return false
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

struct ManualUpdateBuild: Equatable, Comparable, Sendable, CustomStringConvertible {
    let value: Int

    init(_ string: String) throws {
        guard !string.isEmpty, string.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(string) else {
            throw ManualUpdateError.invalidApplication("invalid numeric build number")
        }
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    var description: String { String(value) }
}

enum ManualUpdateClassification: String, Equatable, Sendable {
    case newerMarketingVersion
    case newerBuild
    case sameVersionCleanReinstall
    case older
    case unsupportedBaseline
}

enum ManualUpdateOperation: String, Codable, Sendable {
    case update
    case cleanReinstall
}

enum ManualUpdateSignature: Equatable, Sendable {
    case developerTeam(String)
    case adHoc
}

enum ManualUpdateArchitecture {
    static let supported: Set<String> = ["arm64", "x86_64"]
}

struct ManualUpdateCandidate: Equatable, Identifiable, Sendable {
    let id: UUID
    let archiveSHA256: String
    let applicationTreeSHA256: String
    let stagedApplicationURL: URL
    let bundleIdentifier: String
    let editionID: String
    let marketingVersion: ManualUpdateVersion
    let build: ManualUpdateBuild
    let installedMarketingVersion: ManualUpdateVersion
    let installedBuild: ManualUpdateBuild
    let installedApplicationTreeSHA256: String
    let installedSignature: ManualUpdateSignature
    let installedArchitectures: Set<String>
    let executableName: String
    let architectures: Set<String>
    let signature: ManualUpdateSignature
    let helperSHA256: String
    let helperArchitectures: Set<String>
    let helperSignature: ManualUpdateSignature
    let classification: ManualUpdateClassification

    init(
        id: UUID = UUID(), archiveSHA256: String, applicationTreeSHA256: String,
        stagedApplicationURL: URL, bundleIdentifier: String, editionID: String,
        marketingVersion: ManualUpdateVersion, build: ManualUpdateBuild,
        installedMarketingVersion: ManualUpdateVersion, installedBuild: ManualUpdateBuild,
        installedApplicationTreeSHA256: String, installedSignature: ManualUpdateSignature,
        installedArchitectures: Set<String>,
        executableName: String, architectures: Set<String>, signature: ManualUpdateSignature,
        helperSHA256: String, helperArchitectures: Set<String>, helperSignature: ManualUpdateSignature,
        classification: ManualUpdateClassification
    ) {
        self.id = id
        self.archiveSHA256 = archiveSHA256
        self.applicationTreeSHA256 = applicationTreeSHA256
        self.stagedApplicationURL = stagedApplicationURL
        self.bundleIdentifier = bundleIdentifier
        self.editionID = editionID
        self.marketingVersion = marketingVersion
        self.build = build
        self.installedMarketingVersion = installedMarketingVersion
        self.installedBuild = installedBuild
        self.installedApplicationTreeSHA256 = installedApplicationTreeSHA256
        self.installedSignature = installedSignature
        self.installedArchitectures = installedArchitectures
        self.executableName = executableName
        self.architectures = architectures
        self.signature = signature
        self.helperSHA256 = helperSHA256
        self.helperArchitectures = helperArchitectures
        self.helperSignature = helperSignature
        self.classification = classification
    }

    func permits(_ operation: ManualUpdateOperation) -> Bool {
        switch (classification, operation) {
        case (.newerMarketingVersion, .update), (.newerBuild, .update), (.sameVersionCleanReinstall, .cleanReinstall): true
        default: false
        }
    }
}
