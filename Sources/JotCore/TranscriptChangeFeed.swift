import Foundation
import SQLite3

/// The transcript change feed: its tables and triggers, and the paged read behind `TranscriptStore.changes`.
/// The store passes its connection after checking the arguments and clamping the limit.
enum TranscriptChangeFeed {
    /// One latest entry per live row, plus ID-only tombstones keyed by id and session. Reusing an id in another session must keep the old session's deletion. A deletion allocates its sequence while the parent still exists, then the foreign-key cascade removes the temporary live entry. Both streams share the existing AUTOINCREMENT counter; no source rows or old cursors are rewritten.
    static let schema = """
        CREATE TABLE IF NOT EXISTS transcript_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, transcript_id TEXT NOT NULL UNIQUE REFERENCES transcripts(id) ON DELETE CASCADE ON UPDATE CASCADE);
        CREATE TABLE IF NOT EXISTS transcript_deletions (seq INTEGER PRIMARY KEY, transcript_id TEXT NOT NULL, session_id TEXT NOT NULL, UNIQUE(transcript_id,session_id));
        CREATE INDEX IF NOT EXISTS transcript_deletion_id_sequence ON transcript_deletions(transcript_id,seq DESC);
        CREATE TABLE IF NOT EXISTS transcript_feed_identity (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), generation TEXT NOT NULL);
        INSERT OR IGNORE INTO transcript_feed_identity VALUES(1, lower(hex(randomblob(16))));
        CREATE TRIGGER IF NOT EXISTS transcript_change_delete BEFORE DELETE ON transcripts BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = OLD.id;
          INSERT INTO transcript_changes(transcript_id) VALUES(OLD.id);
          INSERT INTO transcript_deletions(seq,transcript_id,session_id) SELECT seq,transcript_id,OLD.session_id FROM transcript_changes WHERE transcript_id = OLD.id
            ON CONFLICT(transcript_id,session_id) DO UPDATE SET seq=excluded.seq; END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_restore AFTER INSERT ON transcripts BEGIN
          DELETE FROM transcript_deletions WHERE transcript_id = NEW.id AND session_id = NEW.session_id; END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_label_insert AFTER INSERT ON speaker_labels BEGIN
          DELETE FROM transcript_changes WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id=NEW.session_id AND speaker_id=NEW.speaker_id);
          INSERT INTO transcript_changes(transcript_id) SELECT id FROM transcripts WHERE session_id=NEW.session_id AND speaker_id=NEW.speaker_id ORDER BY id; END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_label_update AFTER UPDATE ON speaker_labels WHEN OLD.name IS NOT NEW.name BEGIN
          DELETE FROM transcript_changes WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id=NEW.session_id AND speaker_id=NEW.speaker_id);
          INSERT INTO transcript_changes(transcript_id) SELECT id FROM transcripts WHERE session_id=NEW.session_id AND speaker_id=NEW.speaker_id ORDER BY id; END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_label_delete AFTER DELETE ON speaker_labels BEGIN
          DELETE FROM transcript_changes WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id=OLD.session_id AND speaker_id=OLD.speaker_id);
          INSERT INTO transcript_changes(transcript_id) SELECT id FROM transcripts WHERE session_id=OLD.session_id AND speaker_id=OLD.speaker_id ORDER BY id; END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_insert AFTER INSERT ON transcripts BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.id); END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_update AFTER UPDATE ON transcripts
          WHEN OLD.text IS NOT NEW.text OR OLD.speaker_id IS NOT NEW.speaker_id OR OLD.session_id IS NOT NEW.session_id OR OLD.started_at IS NOT NEW.started_at
            OR OLD.start_seconds IS NOT NEW.start_seconds OR OLD.end_seconds IS NOT NEW.end_seconds OR OLD.mode IS NOT NEW.mode BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.id); END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_readable_insert AFTER INSERT ON transcript_readable BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.transcript_id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.transcript_id); END;
        CREATE TRIGGER IF NOT EXISTS transcript_change_readable_update AFTER UPDATE ON transcript_readable WHEN OLD.text IS NOT NEW.text BEGIN
          DELETE FROM transcript_changes WHERE transcript_id = NEW.transcript_id; INSERT INTO transcript_changes(transcript_id) VALUES(NEW.transcript_id); END;
        """

    /// One page after `cursor` (nil: the current head), with deletions, in sequence order. `limit` is already clamped.
    static func page(_ db: SQLiteConnection, generation: String, since cursor: Int64?, expectedGeneration: String?, sessionID: String?, limit: Int) throws -> TranscriptChanges {
        try db.locked {
            let head = try currentHead(db)
            let reset = (expectedGeneration != nil && expectedGeneration != generation) || (cursor ?? head) > head
            let start = reset ? 0 : cursor ?? head
            guard start < head else { return TranscriptChanges(rows: [], cursor: head, hasMore: false, reset: reset, generation: generation) }
            let size = limit
            // A filtered follower needs its session's last deletion. A global follower needs only the id's latest state:
            // suppress old-session tombstones while that id is live, or retain just its newest deletion when it is gone.
            let stmt = try db.prepare("""
                SELECT c.seq,t.id,t.session_id,t.started_at,t.start_seconds,t.end_seconds,COALESCE(r.text,t.text),t.speaker_id,t.mode,l.name,0
                FROM transcript_changes c JOIN transcripts t ON t.id=c.transcript_id LEFT JOIN transcript_readable r ON r.transcript_id=t.id
                LEFT JOIN speaker_labels l ON t.session_id=l.session_id AND t.speaker_id=l.speaker_id
                WHERE c.seq > ?1 AND c.seq <= ?2 AND (?3 IS NULL OR t.session_id = ?3)
                UNION ALL
                SELECT d.seq,d.transcript_id,d.session_id,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1 FROM transcript_deletions d
                WHERE d.seq > ?1 AND d.seq <= ?2 AND (?3 IS NULL OR d.session_id = ?3)
                  AND NOT EXISTS (SELECT 1 FROM transcripts live WHERE live.id = d.transcript_id AND (?3 IS NULL OR live.session_id = ?3))
                  AND NOT EXISTS (SELECT 1 FROM transcript_deletions newer WHERE newer.transcript_id = d.transcript_id AND newer.seq > d.seq
                    AND (?3 IS NULL OR newer.session_id = ?3))
                ORDER BY 1 LIMIT ?4
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, start)
            sqlite3_bind_int64(stmt, 2, head)
            db.bind(sessionID, to: 3, in: stmt)
            sqlite3_bind_int(stmt, 4, Int32(size + 1))
            var rows: [TranscriptChange] = []
            var deleted: [TranscriptDeletion] = []
            var sequences: [Int64] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let sequence = sqlite3_column_int64(stmt, 0)
                sequences.append(sequence)
                if sqlite3_column_int(stmt, 10) == 1 {
                    deleted.append(TranscriptDeletion(id: db.column(stmt, 1)!, sessionID: db.column(stmt, 2)!, sequence: sequence))
                } else {
                    rows.append(TranscriptChange(Transcript(id: db.column(stmt, 1)!, sessionID: db.column(stmt, 2)!, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), startSeconds: sqlite3_column_double(stmt, 4), endSeconds: sqlite3_column_double(stmt, 5), text: db.column(stmt, 6)!, speakerID: db.column(stmt, 7), mode: db.column(stmt, 8)!, speakerLabel: db.column(stmt, 9)), sequence: sequence))
                }
            }
            let hasMore = sequences.count > size
            if hasMore {
                let extra = sequences.removeLast()
                if rows.last?.sequence == extra { rows.removeLast() } else { deleted.removeLast() }
            }
            return TranscriptChanges(rows: rows, cursor: hasMore ? sequences.last! : head, hasMore: hasMore, reset: reset, deleted: deleted, generation: generation)
        }
    }

    /// The newest change sequence ever assigned; 0 before the first row. Caller holds the lock.
    static func currentHead(_ db: SQLiteConnection) throws -> Int64 {
        let stmt = try db.prepare("SELECT seq FROM sqlite_sequence WHERE name = 'transcript_changes'")
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return 0 }
        guard status == SQLITE_ROW else { throw db.error() }
        return sqlite3_column_int64(stmt, 0)
    }
}
