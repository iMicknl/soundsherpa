import Foundation

/// A brand's adapter: it knows how to recognize a device by name and how to read that
/// device's data over an already-open, serialized `DeviceChannel`.
///
/// This is the modularity seam (design step 4). Everything below a plugin is shared and
/// brand-agnostic — the `DeviceChannel` actor that serializes I/O (R7.1), the
/// `ResponseMatcher` that frames replies, the `RFCOMMTransport` that moves bytes. A plugin
/// supplies only the brand-specific knowledge: which names it claims and which byte
/// sequences mean "battery", "firmware", and so on. Supporting a new brand (Sony, etc.) is
/// adding one `DevicePlugin` and registering it — no change to the channel, the transport,
/// or the UI.
///
/// Plugins are value types (or otherwise `Sendable`) so they can be held by the registry
/// and used freely across the concurrency boundaries the channel introduces.
public protocol DevicePlugin: Sendable {
    /// Stable, human-readable brand identifier (e.g. "Bose"). Used for logging and to let
    /// the registry report which plugin handled a device.
    var identifier: String { get }

    /// Whether this plugin speaks the protocol of the device advertising `name`. Matching is
    /// name-based because that is all the host reliably knows before any channel is open.
    func handles(deviceNamed name: String) -> Bool

    /// Read the current battery percentage (0–100) over the channel, or nil if the device
    /// doesn't answer. Implementations must never throw or fabricate a value — a missing
    /// reply is `nil`, so the UI can distinguish "unknown" from a real reading.
    func readBatteryLevel(over channel: DeviceChannel) async -> Int?

    /// Read the static, slow-changing metadata (firmware, serial, model id, …) over the
    /// channel. Fields the device doesn't report are left nil; a total failure yields an
    /// empty `DeviceMetadata`, never a crash.
    func readMetadata(over channel: DeviceChannel) async -> DeviceMetadata
}
