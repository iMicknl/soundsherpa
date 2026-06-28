import XCTest
@testable import SoundSherpaCore

/// Tests for DeviceMetadata (the static, slow-changing per-device facts) and
/// DeviceMetadataStore (the address-keyed, persistable cache). These are pure and
/// hardware-free: the store reads/writes via an injected data layer, so persistence
/// round-trips without touching the real filesystem.
final class DeviceMetadataStoreTests: XCTestCase {

    // MARK: - DeviceMetadata merge semantics

    func testMergePrefersNewNonNilValues() {
        let old = DeviceMetadata(firmware: "1.0.0", serial: "OLD", modelId: nil,
                                 vendorId: nil, productId: nil, services: nil)
        let new = DeviceMetadata(firmware: "1.0.4", serial: nil, modelId: 0x4014,
                                 vendorId: "0x05A7", productId: "0x4020", services: ["A2DP"])
        let merged = old.merging(new)

        XCTAssertEqual(merged.firmware, "1.0.4")     // new wins
        XCTAssertEqual(merged.serial, "OLD")          // new nil → keep old
        XCTAssertEqual(merged.modelId, 0x4014)        // filled from new
        XCTAssertEqual(merged.vendorId, "0x05A7")
        XCTAssertEqual(merged.productId, "0x4020")
        XCTAssertEqual(merged.services, ["A2DP"])
    }

    func testMergeNeverRegressesToNil() {
        let old = DeviceMetadata(firmware: "1.0.4", serial: "ABC", modelId: 0x4014,
                                 vendorId: "0x05A7", productId: "0x4020", services: ["A2DP"])
        let empty = DeviceMetadata()
        let merged = old.merging(empty)
        XCTAssertEqual(merged, old)
    }

    // MARK: - Store get/put keyed by address

    func testPutThenGetByAddress() {
        let store = DeviceMetadataStore(persistence: InMemoryPersistence())
        let meta = DeviceMetadata(firmware: "1.0.4", serial: "ABC")
        store.put(meta, for: "AA:BB:CC:DD:EE:FF")

        XCTAssertEqual(store.metadata(for: "AA:BB:CC:DD:EE:FF"), meta)
        XCTAssertNil(store.metadata(for: "11:22:33:44:55:66"))
    }

    func testAddressLookupIsCaseInsensitive() {
        let store = DeviceMetadataStore(persistence: InMemoryPersistence())
        store.put(DeviceMetadata(firmware: "1.0.4"), for: "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(store.metadata(for: "AA:BB:CC:DD:EE:FF")?.firmware, "1.0.4")
    }

    func testPutMergesIntoExisting() {
        let store = DeviceMetadataStore(persistence: InMemoryPersistence())
        store.put(DeviceMetadata(firmware: "1.0.4", serial: "ABC"), for: "AA:BB:CC:DD:EE:FF")
        // A later partial fetch (only model id) must not wipe firmware/serial.
        store.put(DeviceMetadata(modelId: 0x4014), for: "AA:BB:CC:DD:EE:FF")

        let got = store.metadata(for: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(got?.firmware, "1.0.4")
        XCTAssertEqual(got?.serial, "ABC")
        XCTAssertEqual(got?.modelId, 0x4014)
    }

    // MARK: - Persistence round-trip

    func testPersistsAcrossStoreInstances() {
        let persistence = InMemoryPersistence()
        let first = DeviceMetadataStore(persistence: persistence)
        first.put(DeviceMetadata(firmware: "1.0.4", serial: "ABC", modelId: 0x4014),
                  for: "AA:BB:CC:DD:EE:FF")

        // A fresh store backed by the same persistence must see the saved data.
        let second = DeviceMetadataStore(persistence: persistence)
        let got = second.metadata(for: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(got?.firmware, "1.0.4")
        XCTAssertEqual(got?.serial, "ABC")
        XCTAssertEqual(got?.modelId, 0x4014)
    }

    func testHandlesEmptyAndCorruptPersistenceGracefully() {
        // Empty store: no data, no crash.
        let empty = DeviceMetadataStore(persistence: InMemoryPersistence())
        XCTAssertNil(empty.metadata(for: "AA:BB:CC:DD:EE:FF"))

        // Corrupt blob: must not crash, behaves as empty.
        let corrupt = InMemoryPersistence(data: Data([0x00, 0x01, 0x02, 0xFF]))
        let store = DeviceMetadataStore(persistence: corrupt)
        XCTAssertNil(store.metadata(for: "AA:BB:CC:DD:EE:FF"))
    }
}

/// Simple in-memory MetadataPersistence for tests — stands in for the on-disk file.
private final class InMemoryPersistence: MetadataPersistence {
    private var stored: Data?
    init(data: Data? = nil) { self.stored = data }
    func load() -> Data? { stored }
    func save(_ data: Data) { stored = data }
}
