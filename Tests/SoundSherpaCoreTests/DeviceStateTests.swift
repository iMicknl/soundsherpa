import XCTest
@testable import SoundSherpaCore

final class DeviceStateTests: XCTestCase {
    func testEmptyStateHasAllNilFields() {
        let s = DeviceState()
        XCTAssertNil(s.battery)
        XCTAssertNil(s.anc)
        XCTAssertNil(s.equalizer)
        XCTAssertNil(s.noiseCancellationLevel)
        XCTAssertNil(s.selfVoice)
        XCTAssertNil(s.autoOff)
        XCTAssertNil(s.buttonAction)
        XCTAssertNil(s.promptLanguage)
        XCTAssertNil(s.voicePromptsEnabled)
    }

    func testANCStateEquatableAndDefaults() {
        let a = ANCState(mode: .ambient, ambientLevel: 12, focusOnVoice: true)
        XCTAssertEqual(a.mode, .ambient)
        XCTAssertEqual(a.ambientLevel, 12)
        XCTAssertEqual(a.focusOnVoice, true)

        let plain = ANCState(mode: .off)
        XCTAssertNil(plain.ambientLevel)
        XCTAssertNil(plain.focusOnVoice)
        XCTAssertEqual(plain, ANCState(mode: .off))
        XCTAssertNotEqual(plain, ANCState(mode: .noiseCancelling))
    }

    func testEqualizerStateDefaults() {
        let e = EqualizerState()
        XCTAssertNil(e.presetId)
        XCTAssertTrue(e.bands.isEmpty)
        XCTAssertEqual(EqualizerState(presetId: 2, bands: [0, -3, 5]),
                       EqualizerState(presetId: 2, bands: [0, -3, 5]))
    }

    func testDeviceStateCarriesBoseParityFields() {
        var s = DeviceState()
        s.noiseCancellationLevel = .high
        s.autoOff = .twenty
        s.buttonAction = .noiseCancellation
        s.promptLanguage = .english
        s.voicePromptsEnabled = true
        XCTAssertEqual(s.noiseCancellationLevel, .high)
        XCTAssertEqual(s.autoOff, .twenty)
    }

    func testDeviceFeatureIsCaseIterable() {
        XCTAssertTrue(DeviceFeature.allCases.contains(.noiseCancellation))
        XCTAssertTrue(DeviceFeature.allCases.contains(.equalizer))
    }
}
