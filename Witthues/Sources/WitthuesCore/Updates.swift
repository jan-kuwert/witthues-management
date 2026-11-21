import Foundation

/// A release on GitHub. Versions are whole numbers counted up by one per release: tag `v12` is version 12.
public struct Release: Sendable, Equatable {
    public var version: Int
    public var notes: String
    public var published: Date?
    /// The zipped app the updater installs.
    public var download: URL
    public var page: URL
}

/// Finds new versions on GitHub and installs them over the running app. The data stays, since it lives in
/// Application Support, the keychain and the main folder, not in the app.
public enum Updates {
    public static let repository = "jan-kuwert/witthues-management"
    /// The release asset with the zipped `Witthüs.app`, built by `.github/workflows/release.yml`.
    public static let assetName = "Witthues.zip"

    /// This app's version from its Info.plist; 0 for builds that were not made by the release workflow.
    public static var current: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// 12 for "v12" or "12"; nil for other tags.
    public static func version(tag: String) -> Int? {
        Int(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
    }

    /// The newest release from the GitHub API's `releases/latest` answer.
    public static func parse(_ data: Data) throws -> Release {
        struct Answer: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let body: String?
            let published_at: Date?
            let html_url: URL
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let a = try decoder.decode(Answer.self, from: data)
        guard let version = version(tag: a.tag_name) else { throw UpdateError("Unbekannte Version „\(a.tag_name)“ auf GitHub.") }
        guard let asset = a.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError("Version \(version) hat noch keine App zum Herunterladen.")
        }
        return Release(version: version, notes: a.body ?? "", published: a.published_at,
                       download: asset.browser_download_url, page: a.html_url)
    }

    /// The newest release. The version comes from where github.com/…/releases/latest leads, which has no rate
    /// limit; the notes come from the GitHub API when it answers (60 requests an hour per network).
    public static func latest() async throws -> Release {
        var head = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: head)
        guard let page = response.url, (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub ist nicht erreichbar.")
        }
        guard page.deletingLastPathComponent().lastPathComponent == "tag", let version = version(tag: page.lastPathComponent) else {
            throw UpdateError("Auf GitHub gibt es noch keine Version.")
        }
        var release = Release(version: version, notes: "", published: nil,
                              download: URL(string: "https://github.com/\(repository)/releases/download/v\(version)/\(assetName)")!,
                              page: page)
        var api = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version)")!)
        api.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, r) = try? await URLSession.shared.data(for: api), (r as? HTTPURLResponse)?.statusCode == 200,
           let details = try? parse(data), details.version == version {
            release.notes = details.notes
            release.published = details.published
        }
        return release
    }

    /// Where a downloaded update waits until it is installed: on quitting, on the next start, or right away.
    public static var stagingFolder: URL { Library.defaultDirectory.appendingPathComponent("Update", isDirectory: true) }

    /// Downloads and unpacks the release into `folder`, replacing an older download, and returns the app in it.
    public static func download(_ release: Release, to folder: URL = stagingFolder) async throws -> URL {
        let fm = FileManager.default
        let (zip, response) = try await URLSession.shared.download(from: release.download)
        defer { try? fm.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download fehlgeschlagen.") }
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard let app = staged(in: folder), app.version == release.version else {
            try? fm.removeItem(at: folder)
            throw UpdateError("Der Download enthält nicht Version \(release.version).")
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.url.path])
        return app.url
    }

    /// The downloaded app waiting in `folder`, with its version.
    public static func staged(in folder: URL = stagingFolder) -> (url: URL, version: Int)? {
        guard let url = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              let version = Int(Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? "")
        else { return nil }
        return (url, version)
    }

    /// Puts the downloaded app in place of the app at `app` and removes the download. The running app keeps
    /// working until it quits; the caller relaunches it when it should start right away.
    public static func installStaged(over app: URL, from folder: URL = stagingFolder) throws {
        guard app.pathExtension == "app" else { throw UpdateError("Updates gehen nur in der installierten App.") }
        guard let new = staged(in: folder) else { throw UpdateError("Kein heruntergeladenes Update gefunden.") }
        _ = try FileManager.default.replaceItemAt(app, withItemAt: new.url)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) ist fehlgeschlagen.") }
    }
}

public struct UpdateError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
