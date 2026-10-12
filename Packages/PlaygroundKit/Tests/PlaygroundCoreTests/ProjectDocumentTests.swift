import Foundation
import Testing
@testable import PlaygroundCore

@Suite struct ProjectDocumentTests {
    @Test func roundTrip() throws {
        var doc = ProjectDocument()
        doc.name = "Demo"
        doc.config.frame.padding = 0.12
        doc.config.background.kind = .gradient
        doc.scene.slices = [Slice(source: SourceRange(0, 5), timeScale: 0.5)]
        doc.scene.zooms = [ZoomRange(source: SourceRange(1, 3), level: 2.2)]
        let data = try TolerantJSON.encode(doc)
        let decoded = try TolerantJSON.decode(ProjectDocument.self, from: data, defaults: ProjectDocument())
        #expect(decoded.name == "Demo")
        #expect(decoded.config == doc.config)
        #expect(decoded.scene.slices == doc.scene.slices)
        #expect(decoded.scene.zooms == doc.scene.zooms)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        // An old file that predates most settings still loads.
        let json = #"{"name":"Old","config":{"frame":{"padding":0.2}},"scenes":[]}"#
        let doc = try TolerantJSON.decode(ProjectDocument.self, from: Data(json.utf8), defaults: ProjectDocument())
        #expect(doc.name == "Old")
        #expect(doc.config.frame.padding == 0.2)
        #expect(doc.config.frame.cornerRadius == FrameConfig().cornerRadius)
        #expect(doc.config.motion == MotionConfig())
    }

    @Test func migratorRejectsNewerFormats() {
        let json = #"{"meta":{"formatVersion":99,"minReaderVersion":99}}"#
        #expect(throws: ProjectMigrator.MigrationError.self) { try ProjectMigrator.migrate(Data(json.utf8)) }
    }

    @Test func bundleSaveLoadAndBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("T.screenplayground"))
        var doc = ProjectDocument()
        for i in 0..<3 {
            doc.name = "v\(i)"
            try bundle.saveDocument(doc)
            Thread.sleep(forTimeInterval: 1.05) // backups are timestamped to the second
        }
        #expect(try bundle.loadDocument().name == "v2")
        let backups = try FileManager.default.contentsOfDirectory(atPath: bundle.backupsFolder.path)
        #expect(backups.count == 2)
    }

    @Test func jsonLinesToleratesTruncatedTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let text = #"{"t":0,"x":1,"y":2}"# + "\n" + #"{"t":1,"x":3,"y":4}"# + "\n" + #"{"t":2,"x":"#
        try text.write(to: url, atomically: true, encoding: .utf8)
        let moves = JSONLines.read(MouseMove.self, from: url)
        #expect(moves.count == 2)
        #expect(moves[1].x == 3)
    }

    @Test func colorHexRoundTrip() {
        #expect(RGBAColor(hex: "#3F37C9").hex == "#3F37C9")
        #expect(RGBAColor(hex: "3f37c980").hex == "#3F37C980")
    }

    @Test func screenRectNormalize() {
        let r = ScreenRect(x: 100, y: 50, width: 200, height: 100)
        let p = r.normalize(x: 200, y: 100)
        #expect(p == NormPoint(0.5, 0.5))
    }
}
