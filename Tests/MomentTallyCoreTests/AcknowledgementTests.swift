import Foundation
import Testing
@testable import MomentTallyKit

/// The Help → Acknowledgements list (#115) against the resource bundle: every
/// entry's license text must load, or the card silently shows nothing when a
/// filename and the list drift apart.
@Suite struct AcknowledgementTests {

    @Test func everyLicenseTextIsBundled() {
        for item in Acknowledgement.all {
            let text = item.licenseText
            #expect(text != nil, "missing license resource \(item.resource).txt")
            // A truncated or mis-copied file would still "load"; a floor
            // catches an empty or placeholder text.
            #expect((text?.count ?? 0) > 200, "\(item.resource).txt looks truncated")
        }
    }
}
