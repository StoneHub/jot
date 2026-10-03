import ApplicationServices

/// A delayed AX result belongs only to the press and application that requested it.
struct ShortcutTargetTicket {
    let generation: Int
    let pid: pid_t

    func accepts(generation current: Int, frontmostPID: pid_t?) -> Bool {
        generation == current && frontmostPID == pid
    }
}
