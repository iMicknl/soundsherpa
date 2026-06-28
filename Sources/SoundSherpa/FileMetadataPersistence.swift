import Foundation
import SoundSherpaCore

/// File-backed `MetadataPersistence` storing the device-metadata cache as JSON under
/// Application Support. Reads/writes the whole blob; the store handles encoding and
/// merge semantics, so this only deals in raw `Data`.
final class FileMetadataPersistence: MetadataPersistence {
    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SoundSherpa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("device-metadata.json")
    }

    func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    func save(_ data: Data) {
        try? data.write(to: fileURL, options: .atomic)
    }
}
