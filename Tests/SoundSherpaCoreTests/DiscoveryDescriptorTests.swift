import XCTest
@testable import SoundSherpaCore

final class DiscoveryDescriptorTests: XCTestCase {
    func testStoresMatchersAndHintsInOrder() {
        let d = DiscoveryDescriptor(
            serviceMatchers: [.serviceName("SPP Dev"), .uuid("0x1101")],
            channelHints: [8, 9, 1, 2, 3])
        XCTAssertEqual(d.serviceMatchers, [.serviceName("SPP Dev"), .uuid("0x1101")])
        XCTAssertEqual(d.channelHints, [8, 9, 1, 2, 3])
    }

    func testServiceMatcherEquatable() {
        XCTAssertEqual(ServiceMatcher.serviceName("SPP Dev"), .serviceName("SPP Dev"))
        XCTAssertNotEqual(ServiceMatcher.serviceName("SPP Dev"), .uuid("0x1101"))
    }
}
