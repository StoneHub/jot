import Foundation

public struct SuggestionSource: Decodable, Equatable, Sendable {
    public init(id: String, kind: String, role: String, speaker: String? = nil, origin: String,
                scope: Scope, timestamp: String, revision: Int, status: Status, text: String,
                derivedFrom: [SourceRevision]? = nil, duplicateOf: String? = nil) {
        self.id = id; self.kind = kind; self.role = role; self.speaker = speaker; self.origin = origin
        self.scope = scope; self.timestamp = timestamp; self.revision = revision; self.status = status
        self.text = text; self.derivedFrom = derivedFrom; self.duplicateOf = duplicateOf
    }
    public enum Status: String, Decodable, Sendable { case current, stale, deleted }
    public struct Scope: Decodable, Equatable, Sendable {
        public init(project: String? = nil, conversation: String? = nil, session: String? = nil) {
            self.project = project; self.conversation = conversation; self.session = session
        }
        public var project: String?
        public var conversation: String?
        public var session: String?
    }

    public let id: String
    public let kind: String
    public let role: String
    public let speaker: String?
    public let origin: String
    public let scope: Scope
    /// UTC `yyyy-MM-ddTHH:mm:ssZ`, so string order is time order.
    public let timestamp: String
    public var revision: Int
    public var status: Status
    public let text: String
    public let derivedFrom: [SourceRevision]?
    public let duplicateOf: String?
}
