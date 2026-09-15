import Foundation

/// The parts of a GitHub release the updater needs; decoded from the "latest release" endpoint.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let tag: String
    public let pageURL: URL
    public let notes: String
    public let downloadURL: URL
    public let assetSize: Int64
    public var firstNoteLine: String {
        notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
    public enum ParseError: Error, Equatable, LocalizedError {
        case badTag(String), noAsset(String), badJSON
        public var errorDescription: String? {
            switch self {
            case .badTag(let tag): return "Release tag \(tag) is not a version."
            case .noAsset(let name): return "Release has no asset named \(name)."
            case .badJSON: return "Release response could not be read."
            }
        }
    }
    private struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int64 }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
    }
    /// `assetNamed` receives the parsed version and returns the asset name to look for, e.g. Jot-<version>.zip.
    public static func latest(from data: Data, assetNamed: (SemanticVersion) -> String) throws -> ReleaseInfo {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw ParseError.badJSON }
        guard let version = SemanticVersion.parse(payload.tag_name) else { throw ParseError.badTag(payload.tag_name) }
        let wanted = assetNamed(version)
        guard let asset = payload.assets.first(where: { $0.name == wanted }) else { throw ParseError.noAsset(wanted) }
        return ReleaseInfo(version: version, tag: payload.tag_name, pageURL: payload.html_url, notes: payload.body ?? "",
                           downloadURL: asset.browser_download_url, assetSize: asset.size)
    }
}
