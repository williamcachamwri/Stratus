import XCTest
@testable import StratusCore

final class EncryptionManifestRoundTripTests: XCTestCase {
    func testManifestRoundTripsThroughJSON() throws {
        var manifest = EncryptionManifest()
        manifest.add(entry: EncryptionManifest.ManifestEntry(
            originalName: "report.pdf",
            encryptedName: "4f1c2a.strs",
            originalSize: 1024,
            encryptedSize: 1088,
            contentType: "application/pdf",
            originalChecksum: String(repeating: "a", count: 64),
            encryptedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let data = try manifest.serializedJSON()
        let decoded = try EncryptionManifest.from(json: data)

        XCTAssertEqual(decoded.encryptedName(for: "report.pdf"), "4f1c2a.strs")
        XCTAssertEqual(decoded.originalName(for: "4f1c2a.strs"), "report.pdf")
    }

    func testManifestSidecarNameIsStable() {
        XCTAssertEqual(EncryptionManifest.sidecarName(for: "/Vault/report.pdf"), ".stratus_enc_manifest")
    }
}
