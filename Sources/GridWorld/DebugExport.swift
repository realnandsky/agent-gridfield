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

    private let automaticRoot: URL?
    private(set) var currentJournal: DebugJournal?

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
        pruneClosedSessions(in: root)
        return DebugExport(automaticRoot: root)
    }

    init(directory: URL, segmentLimit: Int? = nil) throws {
        automaticRoot = nil
        currentJournal = try DebugJournal(directory: directory, segmentLimit: segmentLimit)
    }

    private init(automaticRoot: URL) {
        self.automaticRoot = automaticRoot
    }

    @discardableResult
    func beginRun(model: String, effort: String, at start: Date = Date()) -> Bool {
        guard let automaticRoot else { return false }
        closeRun()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let timestamp = formatter.string(from: start)
        let prefix = "\(Self.pathComponent(model, fallback: "model"))_\(Self.pathComponent(effort, fallback: "automatic"))_\(timestamp)"
        let processSuffix = "_p\(getpid())"
        let segmentLimit = 16 * 1024 * 1024
        do {
            let path = automaticRoot.appendingPathComponent(prefix + processSuffix, isDirectory: true)
            do {
                currentJournal = try DebugJournal(directory: path, segmentLimit: segmentLimit)
            } catch let error as POSIXError where error.code == .EEXIST {
                let suffix = UUID().uuidString.prefix(8).lowercased()
                let alternate = automaticRoot.appendingPathComponent("\(prefix)-\(suffix)\(processSuffix)", isDirectory: true)
                currentJournal = try DebugJournal(directory: alternate, segmentLimit: segmentLimit)
            }
        } catch {
            Self.logger.error("Cannot start run debug export: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    func closeRun() {
        if automaticRoot != nil { currentJournal = nil }
    }

    func event(_ kind: String, _ payload: some Encodable) {
        currentJournal?.event(kind, payload)
    }

    func snapshot(_ state: some Encodable) {
        currentJournal?.snapshot(state)
    }

    private static func pathComponent(_ value: String, fallback: String) -> String {
        let cleaned = String(value.replacingOccurrences(of: "[^a-zA-Z0-9.-]+", with: "-", options: .regularExpression)
            .prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func sessionPID(_ name: String) -> pid_t? {
        let parts = name.split(separator: "-", maxSplits: 2)
        if parts.count == 3, parts[0] == "session", UUID(uuidString: String(parts[2])) != nil {
            return pid_t(parts[1])
        }
        let pattern = #"_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}(?:-[a-f0-9]{8})?_p\d+$"#
        guard name.range(of: pattern, options: .regularExpression) != nil,
              let suffix = name.split(separator: "_").last else { return nil }
        return pid_t(suffix.dropFirst())
    }

    private static func pruneClosedSessions(in root: URL) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys),
                                                                 options: .skipsHiddenFiles) else { return }
        let closedSessions: [(url: URL, created: Date)] = directories.compactMap { url in
            guard let pid = sessionPID(url.lastPathComponent), pid > 0,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink == false,
                  let created = values.creationDate, kill(pid, 0) == -1, errno == ESRCH else { return nil }
            return (url, created)
        }
        for session in closedSessions.sorted(by: { $0.created > $1.created }).dropFirst(3) {
            try? manager.removeItem(at: session.url)
        }
    }
}

@MainActor
final class DebugJournal {
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

    init(directory: URL, segmentLimit: Int?) throws {
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

    private func write(_ operation: () throws -> Void) {
        guard !failed else { return }
        do {
            try operation()
        } catch {
            failed = true
            DebugExport.logger.error("Debug export stopped: \(error.localizedDescription, privacy: .public)")
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
