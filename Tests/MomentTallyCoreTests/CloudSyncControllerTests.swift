import Foundation
import GRDB
import Testing
@testable import MomentTallyCore

/// The CloudKit trigger shell around the transport — status transitions,
/// lastSyncedAt, and change notification, driven through the fake CK layer.
/// The transport semantics themselves are CloudKitTransportTests' job.
@Suite @MainActor struct CloudSyncControllerTests {

    private func makeController(container: FakeCloudContainer) throws
        -> (controller: CloudSyncController, store: LocalBackend) {
        let store = try LocalBackend(DatabaseQueue())
        try store.connectCloudKit(accountLabel: "tester")
        let controller = CloudSyncController(store: store)
        let engine = FakeCloudEngine(container: container, state: nil)
        engine.delegate = controller.transport
        controller.attach(engine: engine)
        return (controller, store)
    }

    @Test func successfulRunReturnsToIdleAndStamps() async throws {
        let container = FakeCloudContainer()
        let (controller, store) = try makeController(container: container)
        _ = try await store.startTimeSpan(start: Date(), labels: [], note: "one")
        #expect(controller.lastSyncedAt == nil)

        await controller.syncNow()
        #expect(controller.status == .idle)
        #expect(controller.lastSyncedAt != nil)
        #expect(container.recordCount > 0)
    }

    @Test func transportFailureSurfacesAsErrorStatusAndClears() async throws {
        let container = FakeCloudContainer()
        let (controller, store) = try makeController(container: container)
        _ = try await store.startTimeSpan(start: Date(), labels: [], note: "queued")

        container.offline = true
        await controller.syncNow()
        guard case .error = controller.status else {
            Issue.record("expected .error, got \(controller.status)")
            return
        }

        container.offline = false
        await controller.syncNow()
        #expect(controller.status == .idle)
    }

    @Test func pullFiresOnLocalChange() async throws {
        let container = FakeCloudContainer()
        let (a, aStore) = try makeController(container: container)
        _ = try await aStore.startTimeSpan(start: Date(), labels: [], note: "shared")
        await a.syncNow()

        let (b, _) = try makeController(container: container)
        var changes = 0
        b.onLocalChange = { changes += 1 }
        await b.syncNow()
        #expect(changes == 1)

        // Nothing new: no change callback.
        await b.syncNow()
        #expect(changes == 1)
    }
}
