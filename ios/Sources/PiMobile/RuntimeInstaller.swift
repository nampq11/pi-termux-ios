import Foundation

/// Installs the bundled JS runtime payload from the app bundle into the app's
/// Application Support directory.
///
/// Layout under Application Support/PiMobile (mirrors Android's filesDir):
///   runtime/  server.mjs + node_modules + public (replaced on upgrade)
///   home/     HOME ($HOME/.pi-mobile for bridge state, $HOME/.pi/agent for auth)
///   work/     default agent working directory
///   tmp/      TMPDIR
///
/// There is no termux rootfs on iOS: the Node engine is linked into the app
/// and no external binaries are exec'd. home/ and work/ (user data) are never
/// touched by reinstalls; runtime/ is replaced as a whole so files removed
/// from a newer bundle do not linger.
enum RuntimeInstaller {

    /// Bump when the installer logic itself changes (not on every payload).
    static let runtimeVersion = 1

    enum InstallerError: LocalizedError {
        case missingResource(String)
        case badFingerprint
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): return "bundled \(name) is missing"
            case .badFingerprint: return "invalid payload fingerprint"
            case .extractionFailed(let detail): return "runtime extraction failed: \(detail)"
            }
        }
    }

    static func rootDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PiMobile", isDirectory: true)
    }

    static func isInstalled(fingerprint: String) -> Bool {
        let stamp = rootDirectory().appendingPathComponent(".runtime-version")
        return (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            == fingerprint
    }

    /// Installs (or reinstalls) the runtime. Cheap no-op when the stamp matches.
    static func installIfNeeded() throws {
        let payloadZip = try bundled("runtime", "zip")
        let fingerprint = try Self.fingerprint
        if isInstalled(fingerprint: fingerprint) {
            try ensureDirectories()
            return
        }

        let root = rootDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // invalidate first: an interrupted install must not look complete
        try? fm.removeItem(at: root.appendingPathComponent(".runtime-version"))
        try? fm.removeItem(at: root.appendingPathComponent("runtime"))

        do {
            try RuntimeArchive.extract(archiveURL: payloadZip, into: root)
        } catch {
            throw InstallerError.extractionFailed(error.localizedDescription)
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("runtime/server.mjs").path) else {
            throw InstallerError.extractionFailed("server.mjs missing after extraction")
        }
        try ensureDirectories()

        // stamp last. Atomic write = write-to-temp + rename(2), which replaces
        // an old stamp or creates a fresh one, matching Android's renameTo.
        // replaceItemAt is not usable here: it requires the destination to
        // already exist, so it could never write a first-install stamp.
        let stamp = root.appendingPathComponent(".runtime-version")
        try fingerprint.data(using: .utf8)?.write(to: stamp, options: .atomic)
    }

    static func ensureDirectories() throws {
        let root = rootDirectory()
        for name in ["home", "work", "tmp", "home/.pi-mobile"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    /// `<runtimeVersion>:<sha256>` from the bundled payload.sha256.
    static var fingerprint: String {
        get throws {
            let shaFile = try bundled("payload", "sha256")
            let sha = (try String(contentsOf: shaFile, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else {
                throw InstallerError.badFingerprint
            }
            return "\(runtimeVersion):\(sha)"
        }
    }

    private static func bundled(_ resource: String, _ ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: resource, withExtension: ext) else {
            throw InstallerError.missingResource("\(resource).\(ext)")
        }
        return url
    }
}
