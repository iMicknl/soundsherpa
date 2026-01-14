import Foundation

/// Delegate protocol for plugin discovery events
public protocol DeviceRegistryDelegate: AnyObject {
    /// Called when a plugin is successfully loaded
    func registry(_ registry: DeviceRegistry, didLoadPlugin plugin: DevicePlugin)
    
    /// Called when a plugin fails to load
    func registry(_ registry: DeviceRegistry, didFailToLoadPluginAt url: URL, error: Error)
    
    /// Called when plugin discovery completes
    func registryDidCompleteDiscovery(_ registry: DeviceRegistry, loadedCount: Int, failedCount: Int)
    
    /// Called when a plugin is dynamically added at runtime (hot-swap)
    func registry(_ registry: DeviceRegistry, didHotLoadPlugin plugin: DevicePlugin)
    
    /// Called when a plugin is dynamically removed at runtime (hot-swap)
    func registry(_ registry: DeviceRegistry, didHotUnloadPluginId pluginId: String)
}

/// Default empty implementation for optional delegate methods
public extension DeviceRegistryDelegate {
    func registry(_ registry: DeviceRegistry, didLoadPlugin plugin: DevicePlugin) {}
    func registry(_ registry: DeviceRegistry, didFailToLoadPluginAt url: URL, error: Error) {}
    func registryDidCompleteDiscovery(_ registry: DeviceRegistry, loadedCount: Int, failedCount: Int) {}
    func registry(_ registry: DeviceRegistry, didHotLoadPlugin plugin: DevicePlugin) {}
    func registry(_ registry: DeviceRegistry, didHotUnloadPluginId pluginId: String) {}
}

/// Registry that manages device plugins
public class DeviceRegistry {
    /// Registered plugins
    private var plugins: [DevicePlugin] = []
    
    /// Currently active plugin
    private var activePlugin: DevicePlugin?
    
    /// Currently connected device
    private var activeDevice: BluetoothDevice?
    
    /// Plugins directory URL
    private let pluginsDirectory: URL?
    
    /// Delegate for plugin discovery events
    public weak var delegate: DeviceRegistryDelegate?
    
    /// Built-in plugin factories (for programmatic registration)
    private var builtInPluginFactories: [() -> DevicePlugin] = []
    
    /// File manager for directory operations
    private let fileManager: FileManager
    
    /// Directory monitor for hot-swapping support
    private var directoryMonitor: PluginDirectoryMonitor?
    
    /// Whether hot-swapping is enabled
    public private(set) var isHotSwappingEnabled: Bool = false
    
    /// Mapping of plugin bundle URLs to plugin IDs for hot-swap tracking
    private var pluginBundleMap: [URL: String] = [:]
    
    /// Default plugins directory
    public static var defaultPluginsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SoundSherpa/Plugins")
    }
    
    /// Initialize with optional plugins directory
    public init(pluginsDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.pluginsDirectory = pluginsDirectory ?? DeviceRegistry.defaultPluginsDirectory
        self.fileManager = fileManager
    }
    
    /// Register a built-in plugin factory for programmatic plugin creation
    public func registerBuiltInPluginFactory(_ factory: @escaping () -> DevicePlugin) {
        builtInPluginFactories.append(factory)
    }
    
    /// Discover and load all plugins from the plugins directory at startup
    /// This includes both built-in plugins and dynamically loaded plugins
    ///
    /// **Validates: Requirements 1.1, 9.3**
    @discardableResult
    public func discoverAndLoadPlugins() throws -> DiscoveryResult {
        var loadedCount = 0
        var failedCount = 0
        var errors: [PluginLoadError] = []
        
        // Load built-in plugins first
        for factory in builtInPluginFactories {
            let plugin = factory()
            do {
                try register(plugin: plugin)
                loadedCount += 1
                delegate?.registry(self, didLoadPlugin: plugin)
            } catch {
                failedCount += 1
                errors.append(PluginLoadError(pluginId: plugin.pluginId, error: error))
                
                // Log the error but continue with other plugins (graceful degradation)
                ErrorLogger.shared.log(
                    error,
                    context: "DeviceRegistry.discoverAndLoadPlugins - Built-in plugin: \(plugin.pluginId)"
                )
            }
        }
        
        // Scan plugins directory if it exists
        if let directory = pluginsDirectory {
            // Create directory if it doesn't exist
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            
            // Scan for plugin bundles
            let result = scanPluginsDirectory(directory)
            loadedCount += result.loadedCount
            failedCount += result.failedCount
            errors.append(contentsOf: result.errors)
        }
        
        delegate?.registryDidCompleteDiscovery(self, loadedCount: loadedCount, failedCount: failedCount)
        
        // Log summary
        if failedCount > 0 {
            ErrorLogger.shared.log(
                .registrationFailed("\(failedCount) plugins failed to load"),
                context: "DeviceRegistry.discoverAndLoadPlugins"
            )
        }
        
        return DiscoveryResult(loadedCount: loadedCount, failedCount: failedCount, errors: errors)
    }
    
    /// Scan a directory for plugin bundles and load them
    /// **Validates: Requirements 9.3**
    private func scanPluginsDirectory(_ directory: URL) -> DiscoveryResult {
        var loadedCount = 0
        var failedCount = 0
        var errors: [PluginLoadError] = []
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            ErrorLogger.shared.log(
                .pluginValidationFailed("Could not read plugins directory"),
                context: "DeviceRegistry.scanPluginsDirectory"
            )
            return DiscoveryResult(loadedCount: 0, failedCount: 0, errors: [])
        }
        
        for itemURL in contents {
            // Look for .bundle or .plugin directories
            let pathExtension = itemURL.pathExtension.lowercased()
            if pathExtension == "bundle" || pathExtension == "plugin" {
                do {
                    if let plugin = try loadPluginBundle(at: itemURL) {
                        try register(plugin: plugin)
                        loadedCount += 1
                        delegate?.registry(self, didLoadPlugin: plugin)
                    }
                } catch {
                    failedCount += 1
                    errors.append(PluginLoadError(url: itemURL, error: error))
                    delegate?.registry(self, didFailToLoadPluginAt: itemURL, error: error)
                    
                    // Log the error but continue with other plugins (graceful degradation)
                    ErrorLogger.shared.log(
                        error,
                        context: "DeviceRegistry.scanPluginsDirectory - \(itemURL.lastPathComponent)"
                    )
                }
            }
        }
        
        return DiscoveryResult(loadedCount: loadedCount, failedCount: failedCount, errors: errors)
    }
    
    /// Load a plugin from a bundle at the specified URL
    /// - Parameter url: URL to the plugin bundle
    /// - Returns: The loaded plugin, or nil if loading failed
    private func loadPluginBundle(at url: URL) throws -> DevicePlugin? {
        // Load the bundle
        guard let bundle = Bundle(url: url) else {
            throw DeviceError.pluginValidationFailed("Could not load bundle at \(url.path)")
        }
        
        // Load the bundle's executable
        guard bundle.load() else {
            throw DeviceError.pluginValidationFailed("Could not load bundle executable at \(url.path)")
        }
        
        // Look for the principal class
        guard let principalClass = bundle.principalClass as? DevicePlugin.Type else {
            throw DeviceError.pluginValidationFailed("Bundle does not have a valid DevicePlugin principal class")
        }
        
        // Create an instance of the plugin
        // Note: This requires the plugin class to have an init() method
        let plugin = principalClass.init()
        
        return plugin
    }
    
    /// Register a plugin with the registry (validates required methods are implemented)
    public func register(plugin: DevicePlugin) throws {
        // Validate plugin
        try validatePlugin(plugin)
        
        // Check for duplicate plugin IDs
        if plugins.contains(where: { $0.pluginId == plugin.pluginId }) {
            throw DeviceError.registrationFailed("Plugin with ID '\(plugin.pluginId)' is already registered")
        }
        
        plugins.append(plugin)
    }
    
    /// Unregister a plugin from the registry
    public func unregister(pluginId: String) {
        plugins.removeAll { $0.pluginId == pluginId }
        
        // If the active plugin was unregistered, deactivate it
        if activePlugin?.pluginId == pluginId {
            deactivatePlugin()
        }
    }
    
    /// Reload plugins from the plugins directory (for hot-swapping support)
    @discardableResult
    public func reloadPlugins() throws -> DiscoveryResult {
        // Clear existing plugins (except active one if connected)
        let activeId = activePlugin?.pluginId
        plugins.removeAll()
        pluginBundleMap.removeAll()
        
        // Re-discover plugins
        let result = try discoverAndLoadPlugins()
        
        // If we had an active plugin, try to restore it
        if let activeId = activeId,
           let restoredPlugin = plugins.first(where: { $0.pluginId == activeId }),
           activeDevice != nil {
            activePlugin = restoredPlugin
            // Note: The connection would need to be re-established by the ConnectionManager
        }
        
        return result
    }
    
    // MARK: - Hot-Swapping Support
    
    /// Enable plugin hot-swapping by monitoring the plugins directory
    /// When enabled, new plugins added to the directory will be automatically loaded,
    /// and removed plugins will be unloaded.
    ///
    /// **Validates: Requirement 1.2**
    public func enableHotSwapping() {
        guard !isHotSwappingEnabled, let directory = pluginsDirectory else { return }
        
        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        
        directoryMonitor = PluginDirectoryMonitor(directory: directory) { [weak self] event in
            self?.handleDirectoryEvent(event)
        }
        
        directoryMonitor?.startMonitoring()
        isHotSwappingEnabled = true
        
        print("[DeviceRegistry] Hot-swapping enabled for directory: \(directory.path)")
    }
    
    /// Disable plugin hot-swapping
    public func disableHotSwapping() {
        directoryMonitor?.stopMonitoring()
        directoryMonitor = nil
        isHotSwappingEnabled = false
        
        print("[DeviceRegistry] Hot-swapping disabled")
    }
    
    /// Handle directory change events for hot-swapping
    private func handleDirectoryEvent(_ event: PluginDirectoryEvent) {
        switch event {
        case .pluginAdded(let url):
            hotLoadPlugin(at: url)
        case .pluginRemoved(let url):
            hotUnloadPlugin(at: url)
        case .pluginModified(let url):
            // Reload the modified plugin
            hotUnloadPlugin(at: url)
            hotLoadPlugin(at: url)
        }
    }
    
    /// Dynamically load a plugin at runtime (hot-swap)
    /// - Parameter url: URL to the plugin bundle
    private func hotLoadPlugin(at url: URL) {
        do {
            if let plugin = try loadPluginBundle(at: url) {
                try register(plugin: plugin)
                pluginBundleMap[url] = plugin.pluginId
                delegate?.registry(self, didHotLoadPlugin: plugin)
                
                print("[DeviceRegistry] Hot-loaded plugin: \(plugin.displayName) (\(plugin.pluginId))")
            }
        } catch {
            ErrorLogger.shared.log(
                error,
                context: "DeviceRegistry.hotLoadPlugin - \(url.lastPathComponent)"
            )
            delegate?.registry(self, didFailToLoadPluginAt: url, error: error)
        }
    }
    
    /// Dynamically unload a plugin at runtime (hot-swap)
    /// - Parameter url: URL to the plugin bundle that was removed
    private func hotUnloadPlugin(at url: URL) {
        guard let pluginId = pluginBundleMap[url] else { return }
        
        // Don't unload the active plugin if it's currently in use
        if activePlugin?.pluginId == pluginId {
            ErrorLogger.shared.log(
                .registrationFailed("Cannot unload active plugin: \(pluginId)"),
                context: "DeviceRegistry.hotUnloadPlugin"
            )
            return
        }
        
        unregister(pluginId: pluginId)
        pluginBundleMap.removeValue(forKey: url)
        delegate?.registry(self, didHotUnloadPluginId: pluginId)
        
        print("[DeviceRegistry] Hot-unloaded plugin: \(pluginId)")
    }
    
    /// Get the plugins directory URL
    public func getPluginsDirectory() -> URL? {
        return pluginsDirectory
    }
    
    /// Find the best matching plugin for a device (queries all plugins, selects highest confidence)
    public func findPlugin(for device: BluetoothDevice) -> DevicePlugin? {
        var bestPlugin: DevicePlugin?
        var bestScore = 0
        
        for plugin in plugins {
            if let score = plugin.canHandle(device: device), score > bestScore {
                bestScore = score
                bestPlugin = plugin
            }
        }
        
        return bestPlugin
    }
    
    /// Find all plugins that can handle a device, sorted by confidence score (highest first)
    public func findAllMatchingPlugins(for device: BluetoothDevice) -> [(plugin: DevicePlugin, score: Int)] {
        var matches: [(plugin: DevicePlugin, score: Int)] = []
        
        for plugin in plugins {
            if let score = plugin.canHandle(device: device) {
                matches.append((plugin: plugin, score: score))
            }
        }
        
        // Sort by score descending
        return matches.sorted { $0.score > $1.score }
    }
    
    /// Get the currently active plugin
    public func getActivePlugin() -> DevicePlugin? {
        return activePlugin
    }
    
    /// Get the currently connected device
    public func getActiveDevice() -> BluetoothDevice? {
        return activeDevice
    }
    
    /// Activate a plugin for a connected device (called by ConnectionManager)
    public func activatePlugin(_ plugin: DevicePlugin, for device: BluetoothDevice) {
        // Deactivate current plugin if any
        if activePlugin != nil {
            deactivatePlugin()
        }
        
        activePlugin = plugin
        activeDevice = device
    }
    
    /// Deactivate the current plugin (called by ConnectionManager on disconnect)
    public func deactivatePlugin() {
        activePlugin?.disconnect()
        activePlugin = nil
        activeDevice = nil
    }
    
    /// Get all registered plugins
    public func getAllPlugins() -> [DevicePlugin] {
        return plugins
    }
    
    /// Get the number of registered plugins
    public var pluginCount: Int {
        return plugins.count
    }
    
    /// Check if a plugin with the given ID is registered
    public func hasPlugin(withId pluginId: String) -> Bool {
        return plugins.contains { $0.pluginId == pluginId }
    }
    
    /// Get a plugin by its ID
    public func getPlugin(byId pluginId: String) -> DevicePlugin? {
        return plugins.first { $0.pluginId == pluginId }
    }
    
    /// Validate that a plugin implements all required protocol methods
    private func validatePlugin(_ plugin: DevicePlugin) throws {
        // Validate pluginId is not empty
        guard !plugin.pluginId.isEmpty else {
            throw DeviceError.pluginValidationFailed("Plugin ID cannot be empty")
        }
        
        // Validate displayName is not empty
        guard !plugin.displayName.isEmpty else {
            throw DeviceError.pluginValidationFailed("Plugin display name cannot be empty")
        }
        
        // Validate supportedDevices is not empty
        guard !plugin.supportedDevices.isEmpty else {
            throw DeviceError.pluginValidationFailed("Plugin must support at least one device")
        }
        
        // Validate supportedChannelTypes is not empty
        guard !plugin.supportedChannelTypes.isEmpty else {
            throw DeviceError.pluginValidationFailed("Plugin must support at least one channel type")
        }
        
        // Validate each device identifier has at least one identification criterion
        for (index, identifier) in plugin.supportedDevices.enumerated() {
            let hasIdentificationCriteria = 
                identifier.vendorId != nil ||
                identifier.productId != nil ||
                !identifier.serviceUUIDs.isEmpty ||
                identifier.namePattern != nil ||
                identifier.macAddressPrefix != nil
            
            guard hasIdentificationCriteria else {
                throw DeviceError.pluginValidationFailed("Device identifier at index \(index) has no identification criteria")
            }
        }
        
        // Validate confidence scores are within valid range
        for (index, identifier) in plugin.supportedDevices.enumerated() {
            guard identifier.confidenceScore >= 0 && identifier.confidenceScore <= 100 else {
                throw DeviceError.pluginValidationFailed("Device identifier at index \(index) has invalid confidence score: \(identifier.confidenceScore)")
            }
        }
    }
}

// MARK: - Supporting Types

/// Result of plugin discovery operation
public struct DiscoveryResult {
    /// Number of plugins successfully loaded
    public let loadedCount: Int
    
    /// Number of plugins that failed to load
    public let failedCount: Int
    
    /// Errors encountered during loading
    public let errors: [PluginLoadError]
    
    /// Whether all plugins loaded successfully
    public var isSuccess: Bool {
        return failedCount == 0
    }
    
    /// Total number of plugins attempted
    public var totalAttempted: Int {
        return loadedCount + failedCount
    }
}

/// Error information for a failed plugin load
public struct PluginLoadError: Error {
    /// Plugin ID if known
    public let pluginId: String?
    
    /// URL of the plugin bundle if applicable
    public let url: URL?
    
    /// The underlying error
    public let error: Error
    
    public init(pluginId: String? = nil, url: URL? = nil, error: Error) {
        self.pluginId = pluginId
        self.url = url
        self.error = error
    }
    
    public init(pluginId: String, error: Error) {
        self.pluginId = pluginId
        self.url = nil
        self.error = error
    }
    
    public init(url: URL, error: Error) {
        self.pluginId = nil
        self.url = url
        self.error = error
    }
}

// MARK: - Plugin Directory Monitoring

/// Events that can occur in the plugins directory
public enum PluginDirectoryEvent {
    /// A new plugin bundle was added
    case pluginAdded(URL)
    /// A plugin bundle was removed
    case pluginRemoved(URL)
    /// A plugin bundle was modified
    case pluginModified(URL)
}

/// Monitors a directory for plugin changes to support hot-swapping
/// Uses DispatchSource for efficient file system monitoring
///
/// **Validates: Requirement 1.2**
public class PluginDirectoryMonitor {
    
    /// The directory being monitored
    private let directory: URL
    
    /// Callback for directory events
    private let eventHandler: (PluginDirectoryEvent) -> Void
    
    /// File descriptor for the monitored directory
    private var fileDescriptor: Int32 = -1
    
    /// Dispatch source for monitoring
    private var dispatchSource: DispatchSourceFileSystemObject?
    
    /// Queue for monitoring events
    private let monitorQueue = DispatchQueue(label: "com.soundsherpa.pluginmonitor", qos: .utility)
    
    /// Snapshot of plugin bundles for change detection
    private var knownPlugins: Set<URL> = []
    
    /// Timer for periodic scanning (fallback for events that don't trigger dispatch source)
    private var scanTimer: DispatchSourceTimer?
    
    /// Scan interval in seconds
    private let scanInterval: TimeInterval = 5.0
    
    /// Initialize the directory monitor
    /// - Parameters:
    ///   - directory: The directory to monitor
    ///   - eventHandler: Callback for directory events
    public init(directory: URL, eventHandler: @escaping (PluginDirectoryEvent) -> Void) {
        self.directory = directory
        self.eventHandler = eventHandler
    }
    
    deinit {
        stopMonitoring()
    }
    
    /// Start monitoring the directory for changes
    public func startMonitoring() {
        // Take initial snapshot
        knownPlugins = scanForPlugins()
        
        // Open file descriptor for the directory
        fileDescriptor = open(directory.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[PluginDirectoryMonitor] Failed to open directory for monitoring: \(directory.path)")
            // Fall back to timer-based scanning
            startTimerBasedScanning()
            return
        }
        
        // Create dispatch source for file system events
        dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: monitorQueue
        )
        
        dispatchSource?.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }
        
        dispatchSource?.setCancelHandler { [weak self] in
            guard let self = self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        
        dispatchSource?.resume()
        
        // Also start timer-based scanning as a backup
        startTimerBasedScanning()
        
        print("[PluginDirectoryMonitor] Started monitoring: \(directory.path)")
    }
    
    /// Stop monitoring the directory
    public func stopMonitoring() {
        // Stop timer
        scanTimer?.cancel()
        scanTimer = nil
        
        // Stop dispatch source
        dispatchSource?.cancel()
        dispatchSource = nil
        
        print("[PluginDirectoryMonitor] Stopped monitoring")
    }
    
    /// Start timer-based scanning as a fallback
    private func startTimerBasedScanning() {
        scanTimer = DispatchSource.makeTimerSource(queue: monitorQueue)
        scanTimer?.schedule(deadline: .now() + scanInterval, repeating: scanInterval)
        scanTimer?.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }
        scanTimer?.resume()
    }
    
    /// Handle a directory change event
    private func handleDirectoryChange() {
        let currentPlugins = scanForPlugins()
        
        // Find added plugins
        let addedPlugins = currentPlugins.subtracting(knownPlugins)
        for url in addedPlugins {
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler(.pluginAdded(url))
            }
        }
        
        // Find removed plugins
        let removedPlugins = knownPlugins.subtracting(currentPlugins)
        for url in removedPlugins {
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler(.pluginRemoved(url))
            }
        }
        
        // Update snapshot
        knownPlugins = currentPlugins
    }
    
    /// Scan the directory for plugin bundles
    /// - Returns: Set of URLs to plugin bundles
    private func scanForPlugins() -> Set<URL> {
        var plugins = Set<URL>()
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return plugins
        }
        
        for itemURL in contents {
            let pathExtension = itemURL.pathExtension.lowercased()
            if pathExtension == "bundle" || pathExtension == "plugin" {
                plugins.insert(itemURL)
            }
        }
        
        return plugins
    }
}
