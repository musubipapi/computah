import AppKit
import Foundation
import CoreServices

public struct InstalledApplication: Equatable {
    public let name: String
    public let bundleID: String
    public let url: URL
    public let aliases: [String]

    public init(name: String, bundleID: String, url: URL, aliases: [String] = []) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.aliases = [name, url.deletingPathExtension().lastPathComponent] + aliases
    }
}

public enum AppRouting {
    public static func installed() -> [InstalledApplication] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
        ]
        var urls: [URL] = []
        for folder in folders {
            guard let entries = FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
                urls.append(url)
                entries.skipDescendants() // Never offer embedded helper apps as separate installations.
            }
        }
        urls += NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        urls += indexedApplications()
        var seen = Set<String>()
        var result: [InstalledApplication] = []
        for url in urls {
            // The metadata index can include embedded helpers. They are not independent installations.
            guard !url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { continue }
            let infoURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = info["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty, seen.insert(bundleID).inserted else { continue }
            let folderName = url.deletingPathExtension().lastPathComponent
            let bundleName = info["CFBundleName"] as? String
            let displayName = info["CFBundleDisplayName"] as? String
            let name = displayName ?? bundleName ?? folderName
            result.append(InstalledApplication(name: name, bundleID: bundleID, url: url,
                                               aliases: [bundleName, displayName].compactMap { $0 }))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Use the system's current metadata index for custom install locations.
    /// Conventional directories and running apps also work when indexing is unavailable.
    private static func indexedApplications() -> [URL] {
        guard let query = MDQueryCreate(kCFAllocatorDefault,
            "kMDItemContentType == 'com.apple.application-bundle'" as CFString,
            [kMDItemPath] as CFArray, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemPath, index),
                  let path = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    public static func defaultBrowser() -> InstalledApplication? {
        // Resolve the registered HTTPS handler; no browser names or bundle IDs are embedded.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "localhost"
        guard let probe = components.url, let url = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        return InstalledApplication(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                                    url.deletingPathExtension().lastPathComponent, bundleID: id, url: url)
    }

    @MainActor public static func activate(_ app: InstalledApplication, permit: InputPermit = .standalone()) async throws -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let lease: InputLease
            do { lease = try permit.begin() }
            catch { continuation.resume(throwing: error); return }
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { application, error in
                defer { lease.finish() }
                if let error { continuation.resume(throwing: error) }
                else if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: AXFailure.unavailable("App launch returned no application.")) }
            }
        }
        for _ in 0..<20 {
            try permit.check()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier {
                return true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

}
