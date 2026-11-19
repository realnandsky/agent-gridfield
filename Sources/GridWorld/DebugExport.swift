import Darwin
import Foundation
import OSLog

struct APIKeyRedaction {
    private let variants: [String]

    init(_ key: String?) {
        guard let key, !key.isEmpty else {
            variants = []
            return
        }
        let unescaped = JSONEncoder()
        unescaped.outputFormatting = [.withoutEscapingSlashes]
        variants = [key] + [unescaped, JSONEncoder()].compactMap { encoder in
            (try? encoder.encode(key)).map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) }
        }
    }

    func redact(_ text: String) -> String {
        variants.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
}

@MainActor
final class DebugExport {
    static let logger = Logger(subsystem: "io.gridworld.macos", category: "DebugExport")

    private struct Event<Payload: Encodable>: Encodable {
        let schemaVersion = 1
        let sequence: Int
        let timestamp = Date()
        let kind: String
        let data: Payload
    }

    private let stateURL: URL
    private let journalURL: URL
    private let segmentLimit: Int?
    private var journal: FileHandle
    private var segmentBytes = 0
    private let encoder = JSONEncoder()
    private var sequence = 0
    private var redactions: [String: APIKeyRedaction] = [:]
    private var failed = false

    static func launch(arguments: [String], automaticRoot: URL? = nil) throws -> DebugExport? {
        if arguments.contains("--no-debug-export") { return nil }
        if let index = arguments.firstIndex(of: "--debug-dir") {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, arguments[next].hasPrefix("/") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return try DebugExport(directory: URL(fileURLWithPath: arguments[next], isDirectory: true))
        }

        let manager = FileManager.default
        let root = try automaticRoot ?? manager.url(for: .cachesDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("io.gridworld.macos/DebugTrace", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let session = root.appendingPathComponent("session-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        let export = try DebugExport(directory: session, segmentLimit: 16 * 1024 * 1024)
        pruneClosedSessions(in: root)
        return export
    }

    init(directory: URL, segmentLimit: Int? = nil) throws {
        // Bind a fresh private directory to this process so launches cannot overwrite or interleave traces.
        let result = directory.withUnsafeFileSystemRepresentation { path in
            path.map { mkdir($0, 0o700) } ?? -1
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        stateURL = directory.appendingPathComponent("state.json")
        journalURL = directory.appendingPathComponent("events.jsonl")
        self.segmentLimit = segmentLimit
        journal = try Self.openJournal(at: journalURL)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func registerAPIKey(_ key: String?) {
        guard let key, !key.isEmpty, redactions[key] == nil else { return }
        redactions[key] = APIKeyRedaction(key)
    }

    func event(_ kind: String, _ payload: some Encodable) {
        write {
            let event = Event(sequence: sequence + 1, kind: kind, data: payload)
            var data = try encode(event)
            data.append(0x0A)
            if let segmentLimit, segmentBytes > 0, segmentBytes + data.count > segmentLimit {
                try rotateJournal()
            }
            try journal.write(contentsOf: data)
            segmentBytes += data.count
            sequence += 1
        }
    }

    func snapshot(_ state: some Encodable) {
        write {
            try encode(state).write(to: stateURL, options: .atomic)
        }
    }

    private static func openJournal(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func rotateJournal() throws {
        try journal.close()
        let previous = journalURL.deletingLastPathComponent().appendingPathComponent("events.previous.jsonl")
        guard rename(journalURL.path, previous.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        journal = try Self.openJournal(at: journalURL)
        segmentBytes = 0
    }

    private static func pruneClosedSessions(in root: URL) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys),
                                                                 options: .skipsHiddenFiles) else { return }
        let closedSessions: [(url: URL, created: Date)] = directories.compactMap { url in
            let parts = url.lastPathComponent.split(separator: "-", maxSplits: 2)
            guard parts.count == 3, parts[0] == "session", let pid = pid_t(parts[1]), pid > 0,
                  UUID(uuidString: String(parts[2])) != nil,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink == false,
                  let created = values.creationDate, kill(pid, 0) == -1, errno == ESRCH else { return nil }
            return (url, created)
        }
        for session in closedSessions.sorted(by: { $0.created > $1.created }).dropFirst(3) {
            try? manager.removeItem(at: session.url)
        }
    }

    private func write(_ operation: () throws -> Void) {
        guard !failed else { return }
        do {
            try operation()
        } catch {
            failed = true
            Self.logger.error("Debug export stopped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let data = try encoder.encode(value)
        guard !redactions.isEmpty else { return data }
        let json = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: redactStrings(in: json),
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func redactStrings(in value: Any) -> Any {
        switch value {
        case let text as String:
            redactions.values.reduce(text) { $1.redact($0) }
        case let array as [Any]:
            array.map(redactStrings)
        case let dictionary as [String: Any]:
            dictionary.mapValues(redactStrings)
        default:
            value
        }
    }
}
