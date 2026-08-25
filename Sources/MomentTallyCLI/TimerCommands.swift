import ArgumentParser
import Foundation
import MomentTallyCore

// MARK: - moment-tally start

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a moment.",
        discussion: "Errors if a timer is already running — stop it first "
            + "(agent hooks that mean \"switch\" chain `moment-tally stop; moment-tally start ...`).")

    @Option(name: .customShort("l"),
            help: ArgumentHelp("A key=value mark; repeatable.", valueName: "key=value"))
    var labels: [String] = []

    @Option(help: "A note on the moment.")
    var note: String = ""

    @OptionGroup var store: StoreOptions

    func run() async throws {
        try await mappingErrors {
            let labels = try parsedLabels()
            let backend = try store.open()
            let running = try await backend.timers()
            guard running.isEmpty else {
                throw LocalBackend.Error(message: "A timer is already running: "
                    + running.map { describeSpan($0, now: Date()) }.joined(separator: "; ")
                    + ". Stop it first with `moment-tally stop`.")
            }
            // The same guard the app applies on start: every key needs a
            // definition (with the same default color) so the new span's
            // labels render everywhere.
            let known = Set(try await backend.labelDefinitions().map(\.key))
            for label in labels where !known.contains(label.key) {
                try await backend.createLabelDefinition(key: label.key, color: "#2196f3")
            }
            let span = try await backend.startTimeSpan(start: Date(), labels: labels, note: note)
            notifyStoreChanged()
            print("Started #\(span.id)" + (labels.isEmpty ? "" : " " + describe(labels)))
        }
    }

    /// `-l key=value`, split on the first "=" and normalised like the app's
    /// tag editor (lower-case keys, no spaces). Values may contain "=".
    func parsedLabels() throws -> [SpanLabel] {
        try labels.map { raw in
            guard let equals = raw.firstIndex(of: "="), raw.startIndex != equals else {
                throw LocalBackend.Error(message: "Not a mark (expected key=value): -l \(raw)")
            }
            return SpanLabel(key: normalizeKey(String(raw[..<equals])),
                             value: String(raw[raw.index(after: equals)...]))
        }
    }
}

// MARK: - moment-tally stop

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the running moment.",
        discussion: "Stops every running moment (the app allows several). "
            + "Exits 1 when none is running.")

    @OptionGroup var store: StoreOptions

    func run() async throws {
        try await mappingErrors {
            let backend = try store.open()
            let running = try await backend.timers()
            guard !running.isEmpty else {
                log("No running timer.")
                throw ExitCode(1)
            }
            let now = Date()
            for span in running {
                let stopped = try await backend.stopTimeSpan(id: span.id, end: now)
                print("Stopped #\(stopped.id)"
                    + (stopped.labels.isEmpty ? "" : " " + describe(stopped.labels))
                    + " — \(describeDuration(from: stopped.start, to: now))")
            }
            notifyStoreChanged()
        }
    }
}

// MARK: - moment-tally status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the running moment, if any.",
        discussion: "Exits 0 when a timer is running, 1 when idle — usable "
            + "directly in scripts: `if moment-tally status -q; then ...`.")

    @Flag(help: "Machine-readable output.")
    var json = false

    @Flag(name: .customShort("q"), help: "No output; just the exit code.")
    var quiet = false

    @OptionGroup var store: StoreOptions

    /// The `--json` document: schema-stable output for hooks, encoded with
    /// the export's encoder (sorted keys, ISO 8601 dates with the machine's
    /// UTC offset).
    struct Output: Codable {
        struct Span: Codable {
            var id: Int
            var start: Date
            var seconds: Int
            var note: String
            var labels: [LocalExport.Label]
        }
        var running: Bool
        var timeSpans: [Span]
    }

    func run() async throws {
        try await mappingErrors {
            let backend = try store.open()
            let running = try await backend.timers()
            let now = Date()
            if quiet {
                // fall through to the exit code
            } else if json {
                let output = Output(running: !running.isEmpty, timeSpans: running.map { span in
                    Output.Span(id: span.id, start: span.start,
                                seconds: max(0, Int(now.timeIntervalSince(span.start))),
                                note: span.note,
                                labels: span.labels.map {
                                    LocalExport.Label(key: $0.key, value: $0.value)
                                })
                })
                let data = try LocalExport.encoder().encode(output)
                print(String(decoding: data, as: UTF8.self))
            } else if running.isEmpty {
                print("No running timer.")
            } else {
                for span in running {
                    print("● " + describeSpan(span, now: now))
                }
            }
            if running.isEmpty {
                throw ExitCode(1)
            }
        }
    }
}

/// One running span on one line: labels, elapsed time, note.
func describeSpan(_ span: TimeSpan, now: Date) -> String {
    var parts = ["#\(span.id)"]
    if !span.labels.isEmpty { parts.append(describe(span.labels)) }
    parts.append("— \(describeDuration(from: span.start, to: now))")
    if !span.note.isEmpty { parts.append("(\(span.note))") }
    return parts.joined(separator: " ")
}
