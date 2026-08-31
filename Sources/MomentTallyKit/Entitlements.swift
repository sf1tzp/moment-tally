import Foundation
import MomentTallyCore
import Security

/// What this particular binary is entitled to do. iCloud entitlements are
/// *restricted*: they only work signed against a provisioning profile that
/// grants them, so dev builds (`swift run`, self-signed certs) ship without
/// them — and a build without the container entitlement must never touch
/// CKContainer, which raises an uncatchable ObjC exception when the
/// identifier isn't in the entitlements. Settings consults this to decide
/// whether iCloud sync is offered at all.
package enum BuildEntitlements {
    #if os(macOS)
    package static let cloudKitAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return ((value as? [String]) ?? []).contains(CloudKitSchema.containerId)
    }()

    /// The container environment this binary is signed for — the claimed
    /// value of com.apple.developer.icloud-container-environment, injected
    /// by sign-app.sh from the provisioning profile ("Development" for a
    /// dev-profile build, "Production" for Developer ID). nil when the
    /// binary claims none; the store's environment guard then stays out of
    /// the way.
    package static let cloudKitEnvironment: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-environment" as CFString, nil)
        else { return nil }
        return value as? String
    }()
    #else
    // SecTask is macOS-only. The iOS shell (ios/project.yml) claims no
    // iCloud entitlements yet, so hard-coding "no CloudKit" is the truthful
    // answer; when iOS sync lands, read the embedded provisioning profile
    // (or gate on the entitlements plist the build injects) instead.
    package static let cloudKitAvailable = false
    package static let cloudKitEnvironment: String? = nil
    #endif
}
