import Foundation

// MARK: - Shared Device Types
//
// Types referenced by both the legacy NSMenu (AppDelegate) and the new SwiftUI views
// (DeviceController). The Bose feature enums (AutoOff/ButtonAction/PromptLanguage) now live
// in SoundSherpaCore so the brand-agnostic state types can reference them.

struct PairedDeviceInfo {
    let address: String
    let name: String
    let isConnected: Bool
    let isCurrentDevice: Bool
}
