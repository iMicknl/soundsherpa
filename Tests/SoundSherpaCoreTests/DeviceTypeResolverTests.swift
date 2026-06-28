import XCTest
@testable import SoundSherpaCore

/// Tests for DeviceTypeResolver — the pure (name, MAC) -> PairedDeviceType logic
/// extracted from AppDelegate. These lock in the existing behavior we must preserve
/// and the device-identification fix (a non-Apple name must not be shown as Apple just
/// because its MAC carries an Apple OUI).
final class DeviceTypeResolverTests: XCTestCase {

    // Real OUI prefixes used as fixtures (present in AppDelegate's tables):
    //   Apple:     00:03:93
    //   Microsoft: 00:15:5D
    private let appleOUI = "00:03:93"
    private let microsoftOUI = "00:15:5D"

    // MARK: - Name-based Apple product detection (must be preserved)

    func testIPhoneName() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Mick's iPhone", address: ""), .iPhone)
    }

    func testIPadName() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Work iPad", address: ""), .iPad)
    }

    func testMacBookName() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Mick's MacBook Pro", address: ""), .macBook)
    }

    func testGenericMacNameButNotMacBook() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Kitchen Mac", address: ""), .mac)
    }

    func testWatchNameWithoutAppleKeyword() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "My Watch", address: ""), .appleWatch)
    }

    func testAirPodsName() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Mick's AirPods", address: ""), .airPods)
    }

    func testNameMatchingIsCaseInsensitive() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "MICK'S IPHONE", address: ""), .iPhone)
    }

    // MARK: - OUI-based detection (must be preserved)

    func testAppleOUIWithUnrecognizedNameResolvesToAppleGeneric() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Living Room", address: "\(appleOUI):11:22:33"), .appleGeneric)
    }

    func testMicrosoftOUIResolvesToWindows() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Office PC", address: "\(microsoftOUI):11:22:33"), .windows)
    }

    func testDashSeparatedAddressIsParsed() {
        let dashed = "\(appleOUI):11:22:33".replacingOccurrences(of: ":", with: "-")
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Living Room", address: dashed), .appleGeneric)
    }

    func testNoSeparatorAddressIsParsed() {
        let compact = "\(appleOUI):11:22:33".replacingOccurrences(of: ":", with: "")
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Living Room", address: compact), .appleGeneric)
    }

    func testUnparseableAddressWithUnknownNameResolvesToUnknown() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Some Speaker", address: "garbage"), .unknown)
    }

    // MARK: - The identification fix: non-Apple name must override Apple OUI

    func testMicrosoftNameWithAppleOUIDoesNotResolveToApple() {
        // A device named "Microsoft ..." whose MAC happens to carry an Apple OUI must
        // NOT be shown with an Apple icon. This is the regression behind the screenshot.
        let type = DeviceTypeResolver.resolve(name: "Microsoft Mouse", address: "\(appleOUI):11:22:33")
        XCTAssertEqual(type, .windows)
    }

    func testWindowsNameResolvesToWindows() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Windows Desktop", address: ""), .windows)
    }

    func testAndroidNameResolvesToAndroid() {
        XCTAssertEqual(DeviceTypeResolver.resolve(name: "Android Phone", address: ""), .android)
    }
}
