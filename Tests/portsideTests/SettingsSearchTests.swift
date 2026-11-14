import XCTest
@testable import portside

final class SettingsSearchTests: XCTestCase {
    private let sample = [
        SettingsSearchEntry(.dock, "Auto-hide", "Hide delay", "timing"),
        SettingsSearchEntry(.menuBar, "Hide again", "Hide again", "rehide timer"),
        SettingsSearchEntry(.menuBar, "Icons", "Menu bar icon", "eye symbol"),
    ]

    func testEveryWordMustMatch() {
        XCTAssertEqual(SettingsSearch.results("menu icon", in: sample).map(\.title), ["Menu bar icon"])
        XCTAssertTrue(SettingsSearch.results("menu walrus", in: sample).isEmpty)
        XCTAssertTrue(SettingsSearch.results("   ", in: sample).isEmpty)
    }

    func testTitleMatchesOutrankKeywords() {
        XCTAssertEqual(SettingsSearch.results("hide", in: sample).map(\.title), ["Hide again", "Hide delay"])
        let entries = sample + [SettingsSearchEntry(.general, nil, "Other", "eye")]
        XCTAssertEqual(SettingsSearch.results("icon", in: entries).first?.title, "Menu bar icon")
    }

    func testKeywordsAndSectionsFindEntries() {
        XCTAssertEqual(SettingsSearch.results("rehide", in: sample).first?.title, "Hide again")
        XCTAssertEqual(SettingsSearch.results("auto-hide", in: sample).first?.title, "Hide delay")
    }

    func testPathNamesThePaneAndSection() {
        XCTAssertEqual(sample[0].path, "Dock > Auto-hide")
        XCTAssertEqual(sample[1].path, "Menu Bar", "a section is not repeated under itself")
    }

    func testNewFeaturesCanBeFound() {
        for query in ["live activities", "time machine", "pills", "portside bar", "glass"] {
            XCTAssertFalse(SettingsSearch.results(query).isEmpty, query)
        }
    }

    func testIdsAreUnique() {
        let ids = SettingsSearch.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// A renamed section header must not leave search pointing nowhere.
    func testEverySectionStillHasItsAnchor() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/portside")
        var text = ""
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)) where url.pathExtension == "swift" {
            text += try String(contentsOf: url, encoding: .utf8)
        }
        let dynamic: Set<String> = ["Visible", "Hidden", "Always Hidden"]
        for section in Set(SettingsSearch.entries.compactMap(\.section)).subtracting(dynamic) {
            // Folded groups anchor their own header: `SettingsFold("Name", ...)` or `SettingsFoldRow`.
            XCTAssertTrue(text.contains(".settingsAnchor(\"\(section)\")") || text.contains("SettingsFold(\"\(section)\",") || text.contains("SettingsFoldRow(\"\(section)\","), section)
        }
    }
}
