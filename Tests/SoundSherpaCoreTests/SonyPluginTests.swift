import XCTest
@testable import SoundSherpaCore

final class SonyPluginTests: XCTestCase {

    func testIdentifier() {
        XCTAssertEqual(SonyPlugin().identifier, "Sony")
    }

    func testHandlesSonyNamedDevices() {
        let p = SonyPlugin()
        XCTAssertTrue(p.handles(deviceNamed: "WH-1000XM5"))
        XCTAssertTrue(p.handles(deviceNamed: "Sony WH-1000XM4"))
        XCTAssertTrue(p.handles(deviceNamed: "wh-1000xm3"))
        XCTAssertFalse(p.handles(deviceNamed: "Bose QC35 II"))
        XCTAssertFalse(p.handles(deviceNamed: ""))
    }

    func testDiscoveryDescriptorListsBothVendorUUIDsV2First() {
        let d = SonyPlugin().discoveryDescriptor
        XCTAssertEqual(d.serviceMatchers, [
            .uuid("956C7B26-D49A-4BA8-B03F-B17D393CB6E2"),  // V2 / XM5
            .uuid("96CC203E-5068-46AD-B32D-E316F5E069BA"),  // V1 / XM4
        ])
        XCTAssertEqual(d.channelHints, [])  // channel resolved from SDP, never hardcoded
    }

    func testSupportedFeatures() {
        let f = SonyPlugin().supportedFeatures
        XCTAssertEqual(f, [.noiseCancellation, .ambientLevel, .focusOnVoice, .equalizer])
        XCTAssertFalse(f.contains(.multipoint))   // deferred (no documented protocol)
        XCTAssertFalse(f.contains(.selfVoice))     // Bose-only
    }
}
