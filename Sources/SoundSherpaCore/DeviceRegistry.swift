import Foundation

/// The lookup that maps a connected device's advertised name to the `DevicePlugin` that
/// speaks its protocol. This is the single extension point for new brands: register one more
/// plugin and the channel/actor/transport/UI layers are untouched.
///
/// Resolution is first-match-wins in registration order, so more specific plugins should be
/// registered ahead of broader ones.
public struct DeviceRegistry: Sendable {
    private let plugins: [DevicePlugin]

    public init(plugins: [DevicePlugin]) {
        self.plugins = plugins
    }

    /// The default set of plugins the app ships with. Add a brand here (and nowhere else) to
    /// support it end-to-end.
    public static var standard: DeviceRegistry {
        DeviceRegistry(plugins: [BosePlugin(), SonyPlugin()])
    }

    /// The first registered plugin that claims `name`, or nil if no brand handles it.
    public func plugin(forDeviceNamed name: String) -> DevicePlugin? {
        plugins.first { $0.handles(deviceNamed: name) }
    }
}
