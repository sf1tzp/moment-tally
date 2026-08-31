import MomentTallyKit
import SwiftUI

/// The entire iOS app target: everything real lives in the package
/// (MomentTallyKit and below), which this shell can only reach through the
/// kit's public façade — `package`-access symbols stop at the package
/// boundary, and SwiftPM derives -package-name from the checkout directory,
/// so the target can't portably join the boundary via SWIFT_PACKAGE_NAME.
@main
struct MomentTallyApp: App {
    init() {
        BrandFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            MomentTallyRootView()
        }
    }
}
