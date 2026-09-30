import CryptoKit
import Foundation
import Darwin

struct ManualUpdateApplicationMetadata: Equatable, Sendable {
    let bundleIdentifier: String
    let editionID: String
    let marketingVersion: ManualUpdateVersion
    let build: ManualUpdateBuild
    let executableName: String
    let executableURL: URL

    static func read(from appURL: URL) throws -> ManualUpdateApplicationMetadata {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: appURL)
        var appInfo = stat()
        guard lstat(appURL.path, &appInfo) == 0, (appInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ManualUpdateError.invalidApplication("application bundle is not a directory")
        }
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard isRegularFile(infoURL),
              let data = try? Data(contentsOf: infoURL),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = values["CFBundleIdentifier"] as? String,
              let editionID = values["NokoEditionID"] as? String,
              let versionString = values["CFBundleShortVersionString"] as? String,
              let buildString = values["CFBundleVersion"] as? String,
              let executable = values["CFBundleExecutable"] as? String,
              executable.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw ManualUpdateError.invalidApplication("application identity or version metadata is missing")
        }
        let executableURL = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executable)
        var executableInfo = stat()
        guard lstat(executableURL.path, &executableInfo) == 0,
              (executableInfo.st_mode & S_IFMT) == S_IFREG,
              executableInfo.st_mode & 0o111 != 0 else {
            throw ManualUpdateError.invalidApplication("the declared executable is missing or not executable")
        }
        return ManualUpdateApplicationMetadata(
            bundleIdentifier: bundleID,
            editionID: editionID,
            marketingVersion: try ManualUpdateVersion(versionString),
            build: try ManualUpdateBuild(buildString),
            executableName: executable,
            executableURL: executableURL
        )
    }

    static func updaterHelperURL(in appURL: URL) throws -> URL {
        let helperURL = appURL.appendingPathComponent("Contents/Helpers/NokoCordUpdateHelper")
        let descriptor = try ManualUpdateTransactionFiles.openRegularFileNoFollow(helperURL.path)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o111 != 0,
              info.st_size > 0,
              info.st_size <= 64 * 1024 * 1024 else {
            throw ManualUpdateError.invalidApplication("the bundled updater helper is missing or not an executable file")
        }
        return helperURL
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

struct ManualUpdateAppValidation: Equatable, Sendable {
    let signature: ManualUpdateSignature
    let architectures: Set<String>
}

protocol ManualUpdateAppValidating: Sendable {
    func validate(appURL: URL, executableURL: URL) throws -> ManualUpdateAppValidation
    func validateStandaloneExecutable(_ executableURL: URL) throws -> ManualUpdateAppValidation
}

extension ManualUpdateAppValidating {
    func validateStandaloneExecutable(_ executableURL: URL) throws -> ManualUpdateAppValidation {
        throw ManualUpdateError.invalidApplication("standalone updater helper validation is unavailable")
    }
}

struct SystemManualUpdateAppValidator: ManualUpdateAppValidating {
    func validate(appURL: URL, executableURL: URL) throws -> ManualUpdateAppValidation {
        let codeResources = appURL.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        var resourcesInfo = stat()
        guard lstat(codeResources.path, &resourcesInfo) == 0,
              (resourcesInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ManualUpdateError.invalidApplication("code signature resources are missing")
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", appURL.path], capture: false)
        return try validateStandaloneExecutable(executableURL)
    }

    func validateStandaloneExecutable(_ executableURL: URL) throws -> ManualUpdateAppValidation {
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", executableURL.path], capture: false)
        let details = try run("/usr/bin/codesign", ["-dv", "--verbose=4", executableURL.path], capture: true)
        let output = String(decoding: details, as: UTF8.self)
        let teamIdentifier = output.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("teamidentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let signature: ManualUpdateSignature
        if let teamIdentifier, !teamIdentifier.isEmpty, teamIdentifier != "-", teamIdentifier.caseInsensitiveCompare("not set") != .orderedSame {
            signature = .developerTeam(teamIdentifier)
        } else {
            // Ad-hoc signatures establish bundle integrity only. They do not
            // authenticate a publisher or provide an identity claim.
            signature = .adHoc
        }
        let architectureOutput = String(decoding: try run("/usr/bin/lipo", ["-archs", executableURL.path], capture: true), as: UTF8.self)
        let architectures = Set(architectureOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init))
        guard !architectures.isEmpty else { throw ManualUpdateError.invalidApplication("the executable has no supported architecture slices") }
        return ManualUpdateAppValidation(signature: signature, architectures: architectures)
    }

    private func run(_ executable: String, _ arguments: [String], capture: Bool) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = capture ? Pipe() : nil
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = capture ? output : FileHandle.nullDevice
        do { try process.run() } catch {
            throw ManualUpdateError.invalidApplication("required signature or architecture tooling is unavailable")
        }
        var data = Data()
        var exceededOutputLimit = false
        if let output {
            let descriptor = output.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    kill(process.processIdentifier, SIGKILL)
                    throw ManualUpdateError.invalidApplication("could not read signature validation output")
                }
                if !exceededOutputLimit {
                    if data.count + count <= 1024 * 1024 {
                        data.append(contentsOf: buffer.prefix(count))
                    } else {
                        exceededOutputLimit = true
                        // Keep draining the pipe after termination is requested
                        // so the child cannot block while exiting.
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        process.waitUntilExit()
        guard !exceededOutputLimit, process.terminationStatus == 0 else {
            throw ManualUpdateError.invalidApplication("code signature or architecture validation failed")
        }
        return data
    }
}
