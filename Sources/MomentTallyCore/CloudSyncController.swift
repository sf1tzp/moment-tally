import Foundation
import Observation

/// The CloudKit counterpart of SyncEngine's trigger shell: observable
/// status for the Settings surface, the periodic background cadence, the
/// debounced kick after local writes, and single-flight syncNow with one
/// queued rerun — wrapped around CloudKitTransport instead of the
/// self-hosted reconciliation. Deliberately the same shape as SyncEngine,
/// so the two transports feel identical to AppModel and Settings; the
/// plumbing is small enough that sharing it would couple more than it
/// saves.
///
/// Owns the engine (the real adapter, or the tests' fake) strongly — the
/// transport's back-reference and the engine's delegate reference are both
/// weak, so this controller is what keeps the trio alive.
@MainActor
@Observable
package final class CloudSyncController {
    package let transport: CloudKitTransport
    package private(set) var engine: (any CloudSyncEngineControl)?

    package var status: SyncStatus = .idle
    package var lastSyncedAt: Date?
    /// Called after a run that changed local data, so the UI reloads.
    package var onLocalChange: () -> Void = {}

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var kickTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false

    package init(store: LocalBackend) {
        transport = CloudKitTransport(store: store)
        lastSyncedAt = (try? store.syncServer())?.lastSyncedAt
    }

    /// Wire the engine in. Separate from init because the engine needs its
    /// delegate (the transport) before it exists — the caller creates the
    /// controller, points the engine's delegate at `transport`, then
    /// attaches.
    package func attach(engine: any CloudSyncEngineControl) {
        self.engine = engine
        transport.engine = engine
    }

    // MARK: Triggers (SyncEngine's, verbatim in shape)

    /// The steady background cadence — with automatic sync off on the
    /// engine, this is also what stands in for push-driven sync in v1.
    package func startPeriodicSync(every seconds: Double = 60) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self?.syncNow()
            }
        }
    }

    /// Cancel all scheduled work (disconnect).
    package func stop() {
        periodicTask?.cancel()
        kickTask?.cancel()
    }

    /// Debounced trigger for "something changed locally".
    package func kick(after seconds: Double = 3) {
        kickTask?.cancel()
        kickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    /// Run a sync immediately; if one is in flight, run another after it.
    package func syncNow() async {
        if syncTask != nil {
            rerunRequested = true
            return
        }
        let task = Task { await runOnce() }
        syncTask = task
        await task.value
        syncTask = nil
        if rerunRequested {
            rerunRequested = false
            await syncNow()
        }
    }

    private func runOnce() async {
        status = .syncing
        do {
            let changed = try await transport.syncNow()
            lastSyncedAt = Date()
            status = .idle
            if changed { onLocalChange() }
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
