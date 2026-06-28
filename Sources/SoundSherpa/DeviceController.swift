import Foundation
import Observation
import SoundSherpaCore

/// Single source of truth the SwiftUI views observe. Holds all device state as
/// observable properties and exposes intent methods the views call. The Bluetooth
/// implementation is migrated in from AppDelegate (Task 4); this shell defines the seam.
@MainActor
@Observable
final class DeviceController {
    // Connection + identity
    var deviceName: String?
    var isConnected: Bool = false
    var batteryLevel: Int?

    // Primary controls
    var ncLevel: NoiseCancellationLevel?
    var selfVoiceLevel: SelfVoiceLevel?

    // Paired devices
    var pairedDevices: [PairedDeviceInfo] = []

    // Advanced settings
    var autoOff: AutoOff?
    var language: PromptLanguage?
    var voicePromptsEnabled: Bool?
    var buttonAction: ButtonAction?

    // Read-only info (nil → row hidden)
    var firmware: String?
    var serial: String?
    var deviceId: String?
    var services: [String]?

    // Intents — bodies filled in Task 4.
    func refresh() {}
    func setNoiseCancellation(_ level: NoiseCancellationLevel) {}
    func setSelfVoice(_ level: SelfVoiceLevel) {}
    func connectPairedDevice(_ device: PairedDeviceInfo) {}
    func disconnectPairedDevice(_ device: PairedDeviceInfo) {}
    func setAutoOff(_ value: AutoOff) {}
    func setLanguage(_ value: PromptLanguage) {}
    func setVoicePrompts(_ on: Bool) {}
    func setButtonAction(_ value: ButtonAction) {}
}
