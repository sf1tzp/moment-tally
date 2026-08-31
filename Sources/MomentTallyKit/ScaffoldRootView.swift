import Foundation
import MomentTallyCore
import SwiftUI

/// The #123 exit-criterion surface, and nothing more: proves the iOS shell
/// opens the real LocalBackend store (or the demo store under
/// MOMENTTALLY_DEMO/--demo), registers brand fonts, and round-trips a span —
/// start, watch it run, stop, see it counted. Deliberately throwaway: #124
/// replaces it with the touch-first launcher and #125 brings the real views
/// into this target.
public struct ScaffoldRootView: View {
    @State private var model = ScaffoldModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Running") {
                    if model.running.isEmpty {
                        Text("Nothing running")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.running) { span in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(span.labels.map { "\($0.key): \($0.value)" }
                                    .joined(separator: "  "))
                                Text(span.start, style: .timer)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop") {
                                Task { await model.stop(span) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                Section {
                    Button("Start a span") {
                        Task { await model.start() }
                    }
                }
                Section("Store") {
                    LabeledContent("Spans this week", value: "\(model.weekCount)")
                    LabeledContent("Demo mode", value: DemoMode.isActive ? "on" : "off")
                    Text(model.storePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Section("Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Moment Tally")
            .toolbar {
                // Palm Springs when the build carries the injected fonts —
                // the visible proof registration ran; absent, nothing shows.
                if let script = BrandFonts.script(24) {
                    ToolbarItem(placement: .principal) {
                        Text("Moment Tally").font(script)
                    }
                }
            }
        }
        .task { await model.load() }
    }
}

@MainActor @Observable
final class ScaffoldModel {
    var running: [TimeSpan] = []
    var weekCount = 0
    var storePath = ""
    var error: String?

    private var backend: LocalBackend?

    func load() async {
        do {
            let backend = try backend
                ?? (DemoMode.isActive ? LocalBackend.demo() : LocalBackend())
            self.backend = backend
            storePath = backend.databaseURL?.path ?? "in-memory"
            running = try await backend.timers()
            let week = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            let page = try await backend.timeSpans(from: week, to: .now, page: nil)
            weekCount = page.timeSpans.count
        } catch {
            self.error = "\(error)"
        }
    }

    func start() async {
        guard let backend else { return }
        do {
            _ = try await backend.startTimeSpan(
                start: .now,
                labels: [SpanLabel(key: "scaffold", value: "ios")],
                note: "")
            await load()
        } catch {
            self.error = "\(error)"
        }
    }

    func stop(_ span: TimeSpan) async {
        guard let backend else { return }
        do {
            _ = try await backend.stopTimeSpan(id: span.id, end: .now)
            await load()
        } catch {
            self.error = "\(error)"
        }
    }
}
