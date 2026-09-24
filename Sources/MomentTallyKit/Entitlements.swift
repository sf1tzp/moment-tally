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
    // SecTask is macOS-only. On iOS the claim is read from the binary
    // itself (EmbeddedEntitlements below) — the same per-build truth the
    // Mac gets from the signature, so a build that shipped without the
    // container never touches CKContainer.
    package static let cloudKitAvailable: Bool = {
        let containers = EmbeddedEntitlements.claims[
            "com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        return containers.contains(CloudKitSchema.containerId)
    }()

    /// The container environment this build runs against. Xcode stamps
    /// no environment into a simulator or Xcode-run device build (Xcode
    /// 26.6: the signed .xcent carries only the container keys); only the
    /// App Store export re-signs with the distribution profile and claims
    /// Production. So an explicit claim wins, and a build without one is
    /// development-signed — Development, which is also what cloudd infers
    /// for it. Never nil while the container is claimed: the environment
    /// guard in AppModel.startSyncIfConfigured must separate a simulator
    /// or dev-device run from the TestFlight build installed over it.
    package static let cloudKitEnvironment: String? = {
        guard cloudKitAvailable else { return nil }
        return EmbeddedEntitlements.claims[
            "com.apple.developer.icloud-container-environment"] as? String ?? "Development"
    }()
    #endif
}

#if !os(macOS)
import MachO

/// The entitlements the running executable was signed with, decoded once.
/// Two places to look, because Xcode embeds them differently per
/// destination: a simulator build links the .xcent into the binary as a
/// `__TEXT,__entitlements` section (LD_ENTITLEMENTS_SECTION) and its
/// ad-hoc signature carries none; a device build carries them in the code
/// signature's entitlements slot, inside `__LINKEDIT`. Both are mapped
/// read-only by dyld, so this is a walk over memory, not a file read.
private enum EmbeddedEntitlements {
    static let claims: [String: Any] = {
        guard let data = sectionEntitlements() ?? signatureEntitlements(),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }()

    /// dyld image 0 is always the main executable — the app target that
    /// was signed, whichever module this code was linked from.
    private static var mainExecutable: UnsafePointer<mach_header_64>? {
        guard let header = _dyld_get_image_header(0),
              header.pointee.magic == MH_MAGIC_64 else { return nil }
        return UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
    }

    private static func sectionEntitlements() -> Data? {
        guard let header = mainExecutable else { return nil }
        var size: UInt = 0
        guard let bytes = getsectiondata(header, "__TEXT", "__entitlements", &size),
              size > 0 else { return nil }
        return Data(bytes: bytes, count: Int(size))
    }

    /// LC_CODE_SIGNATURE → the CMS SuperBlob at `dataoff` in the file,
    /// which maps to `__LINKEDIT`'s address plus the offset into that
    /// segment. The blob indexed as CSSLOT_ENTITLEMENTS (5) is an XML
    /// plist behind an 8-byte header. Every offset is bounds-checked
    /// against the signature's own size, so a malformed signature yields
    /// nil rather than a read past the mapping.
    private static func signatureEntitlements() -> Data? {
        guard let header = mainExecutable else { return nil }
        var linkedit: segment_command_64?
        var signature: linkedit_data_command?
        var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            switch command.cmd {
            case UInt32(LC_SEGMENT_64):
                let segment = cursor.loadUnaligned(as: segment_command_64.self)
                let name = withUnsafeBytes(of: segment.segname) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name == SEG_LINKEDIT { linkedit = segment }
            case UInt32(LC_CODE_SIGNATURE):
                signature = cursor.loadUnaligned(as: linkedit_data_command.self)
            default:
                break
            }
            cursor += Int(command.cmdsize)
        }
        guard let linkedit, let signature,
              signature.dataoff >= linkedit.fileoff,
              UInt64(signature.dataoff) + UInt64(signature.datasize)
                <= linkedit.fileoff + linkedit.filesize
        else { return nil }
        let slide = _dyld_get_image_vmaddr_slide(0)
        let address = Int(linkedit.vmaddr) + slide + Int(signature.dataoff) - Int(linkedit.fileoff)
        guard let superBlob = UnsafeRawPointer(bitPattern: address) else { return nil }
        let size = Int(signature.datasize)
        func word(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= size else { return nil }
            return Int(superBlob.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
        }
        let superBlobMagic = 0xfade0cc0, entitlementsBlobMagic = 0xfade7171
        let entitlementsSlot = 5
        // A real SuperBlob indexes a handful of slots; the cap keeps a
        // corrupt count from turning the walk into a long spin.
        guard word(0) == superBlobMagic, let count = word(8), count <= 64 else { return nil }
        for index in 0..<count {
            let entry = 12 + index * 8
            guard word(entry) == entitlementsSlot, let offset = word(entry + 4),
                  word(offset) == entitlementsBlobMagic, let length = word(offset + 4),
                  length > 8, offset + length <= size
            else { continue }
            return Data(bytes: superBlob + offset + 8, count: length - 8)
        }
        return nil
    }
}
#endif
