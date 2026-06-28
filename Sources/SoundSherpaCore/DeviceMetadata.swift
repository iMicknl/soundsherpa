import Foundation

/// The static, slow-changing facts about a device that are expensive to fetch and worth
/// caching: things we read once on connect and then keep. Distinct from live state
/// (battery, NC level) which is always re-queried.
///
/// Every field is optional because the sources are heterogeneous — firmware/serial/model
/// come over the device's control protocol, while vendor/product/services come from the
/// host Bluetooth (SDP) stack — and any of them may be unavailable on a given connect.
public struct DeviceMetadata: Equatable, Codable, Sendable {
    public var firmware: String?
    public var serial: String?
    /// Vendor-internal model code (e.g. Bose `0x4014`), not a Bluetooth PnP id.
    public var modelId: Int?
    public var vendorId: String?
    public var productId: String?
    public var services: [String]?

    public init(firmware: String? = nil,
                serial: String? = nil,
                modelId: Int? = nil,
                vendorId: String? = nil,
                productId: String? = nil,
                services: [String]? = nil) {
        self.firmware = firmware
        self.serial = serial
        self.modelId = modelId
        self.vendorId = vendorId
        self.productId = productId
        self.services = services
    }

    /// Returns a copy where every non-nil field of `other` overrides this one, and nil
    /// fields of `other` leave the existing value intact. This is the cache-update rule:
    /// a partial fetch never regresses a previously-known value back to "Unknown".
    public func merging(_ other: DeviceMetadata) -> DeviceMetadata {
        DeviceMetadata(
            firmware: other.firmware ?? firmware,
            serial: other.serial ?? serial,
            modelId: other.modelId ?? modelId,
            vendorId: other.vendorId ?? vendorId,
            productId: other.productId ?? productId,
            services: other.services ?? services
        )
    }

    /// True when no field carries a value — used to skip empty writes.
    public var isEmpty: Bool {
        firmware == nil && serial == nil && modelId == nil
            && vendorId == nil && productId == nil && services == nil
    }
}

/// Abstracts where the metadata cache is persisted, so the store can be unit-tested
/// without touching the real filesystem. The app provides a file-backed implementation.
public protocol MetadataPersistence: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

/// An address-keyed cache of `DeviceMetadata`, persisted via an injected `MetadataPersistence`.
///
/// Lookups are case-insensitive on the MAC address. `put` merges into any existing entry
/// (see `DeviceMetadata.merging`) so partial refreshes accumulate rather than overwrite.
/// All mutations write through to persistence immediately, so the cache survives relaunch
/// and is shown instantly on the next connect — even before a channel is healthy.
public final class DeviceMetadataStore {
    private let persistence: MetadataPersistence
    private var entries: [String: DeviceMetadata]

    public init(persistence: MetadataPersistence) {
        self.persistence = persistence
        if let data = persistence.load(),
           let decoded = try? JSONDecoder().decode([String: DeviceMetadata].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    public func metadata(for address: String) -> DeviceMetadata? {
        entries[Self.key(address)]
    }

    /// Merge `metadata` into the entry for `address` and persist. Empty updates to an
    /// absent key are ignored so we don't store hollow records.
    public func put(_ metadata: DeviceMetadata, for address: String) {
        let key = Self.key(address)
        let merged = (entries[key] ?? DeviceMetadata()).merging(metadata)
        guard !merged.isEmpty else { return }
        entries[key] = merged
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        persistence.save(data)
    }

    private static func key(_ address: String) -> String {
        address.uppercased()
    }
}
