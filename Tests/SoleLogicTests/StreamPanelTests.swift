import XCTest
import SoleCore
@testable import SoleLogic

final class StreamPanelTests: XCTestCase {
    private var stats: StreamStats {
        var stats = StreamStats()
        stats.framesPerSecond = 59.6; stats.newPerSecond = 59.6; stats.bitrateMbps = 28.44
        stats.livePingMs = 31; stats.measuredPingMs = 40; stats.screenDelayMs = 22.4; stats.decodeMs = 3.26
        stats.height = 1080; stats.codec = "H.265 Main"; stats.server = "Frankfurt, Germany · A"
        return stats
    }
    private func texts(_ cells: [StreamPanel.Cell]) -> [String] {
        cells.map { [$0.kind.rawValue, $0.value, $0.unit].compactMap { $0 }.joined(separator: " ") }
    }

    func testTheLineHasFourItemsAndANarrowScreenDropsTheBitrateThenTheVideo() {
        XCTAssertEqual(texts(StreamPanel.cells(stats, detail: .full)), ["frames 60", "ping 31 ms", "bitrate 28.4 Mbps", "video 1080p"])
        XCTAssertEqual(texts(StreamPanel.cells(stats, detail: .less)), ["frames 60", "ping 31 ms", "video 1080p"])
        XCTAssertEqual(texts(StreamPanel.cells(stats, detail: .least)), ["frames 60", "ping 31 ms"])
        XCTAssertEqual(StreamPanel.summary(stats), "60 fps · 28.4 Mbps · ping 31 ms · delay ≈53 ms · decoder 3.3 ms · 1080p H.265 · Frankfurt")
    }

    func testBeforeThePingIsMeasuredLiveTheOneOfTheStartStandsIn() {
        var early = stats; early.livePingMs = nil
        XCTAssertTrue(texts(StreamPanel.cells(early, detail: .least)).contains("ping 40 ms"))
        XCTAssertTrue(StreamPanel.summary(early).contains("ping at start 40 ms"))
        early.measuredPingMs = nil
        XCTAssertEqual(texts(StreamPanel.cells(early, detail: .least)), ["frames 60", "ping —"])
        XCTAssertFalse(StreamPanel.summary(early).contains("delay"), "Without a ping no delay is shown")
        early.height = 0; early.codec = ""
        XCTAssertEqual(texts(StreamPanel.cells(early, detail: .less)).last, "video —")
        XCTAssertTrue(StreamPanel.summary(early).contains("— H.264"))
    }

    func testLostFramesColourThePing() {
        var troubled = stats
        XCTAssertEqual(troubled.trouble, .none)
        troubled.recentLostFrames = 1
        XCTAssertEqual(troubled.trouble, .some)
        troubled.recentLostFrames = 30
        XCTAssertEqual(troubled.trouble, .broken)
        troubled.recentLostFrames = 0; troubled.recentFailures = 1
        XCTAssertEqual(troubled.trouble, .broken)
        let cells = StreamPanel.cells(troubled, detail: .full)
        XCTAssertEqual(cells.map(\.trouble), [.none, .broken, .none, .none], "Only the ping cell is colored")
    }

    func testTheFrameRateCountsPicturesThatReallyDiffer() {
        var rated = stats
        XCTAssertFalse(rated.repeats); XCTAssertEqual(rated.framesNote, "fps")
        rated.newPerSecond = 30.2
        XCTAssertTrue(rated.repeats)
        XCTAssertEqual(rated.shownPerSecond, 30.2, accuracy: 0.001)
        XCTAssertEqual(rated.framesNote, "fps · stream 60")
        rated.generation = .active; rated.generatedPerSecond = 29.8
        XCTAssertEqual(rated.shownPerSecond, 60, accuracy: 0.001)
        XCTAssertEqual(rated.framesNote, "fps · +30 generated")
        XCTAssertEqual(StreamPanel.cells(rated, detail: .least).first, StreamPanel.Cell(.frames, "60", "+30"), "The cell shows generated frames after the rate")
        rated.generation = .standby
        XCTAssertEqual(rated.shownPerSecond, 30.2, accuracy: 0.001, "Frames generated while generation is on standby are not counted as shown")
        XCTAssertEqual(rated.framesNote, "fps · generation not needed")
        XCTAssertNil(StreamPanel.cells(rated, detail: .least).first?.unit, "Notes that do not fit the cell go only to the summary")
        rated.generation = .unavailable
        XCTAssertEqual(rated.framesNote, "fps · generation unavailable")
        rated.generation = .off; rated.newPerSecond = 2
        XCTAssertFalse(rated.repeats); XCTAssertEqual(rated.shownPerSecond, 59.6, accuracy: 0.001)
        rated.newPerSecond = 11
        XCTAssertFalse(rated.repeats); XCTAssertEqual(rated.shownPerSecond, 59.6, accuracy: 0.001)
    }

    func testTheEnlargedSizeIsNamedAs4KAnd8K() {
        var enlarged = StreamStats(); enlarged.height = 1080
        XCTAssertEqual(enlarged.videoSize, "1080p")
        enlarged.upscaledHeight = 2160; XCTAssertEqual(enlarged.videoSize, "1080p→4K")
        enlarged.upscaledHeight = 3240; XCTAssertEqual(enlarged.videoSize, "1080p→3240p")
        enlarged.upscaledHeight = 4320; XCTAssertEqual(enlarged.videoSize, "1080p→8K")
    }

    func testTheMenuOverAStreamSaysWhereItComesFromAndNamesItsRows() {
        XCTAssertEqual(stats.facts, ["Frankfurt", "1080p"])
        XCTAssertEqual(StreamStats().facts, [])
        XCTAssertNil(StreamStats().serverCity)
        XCTAssertEqual(StreamMenu.Item.resume.title(fullScreen: false), "Resume")
        XCTAssertEqual(StreamMenu.Item.fullScreen.title(fullScreen: false), "Full screen")
        XCTAssertEqual(StreamMenu.Item.fullScreen.title(fullScreen: true), "Exit full screen")
        XCTAssertEqual(StreamMenu.Item.leave.title(fullScreen: true), "Close game")
        XCTAssertEqual(StreamMenu.Item.stats.isOn(statsVisible: true, generation: false), true)
        XCTAssertEqual(StreamMenu.Item.generation.isOn(statsVisible: true, generation: false), false)
        XCTAssertNil(StreamMenu.Item.resume.isOn(statsVisible: true, generation: true))
        XCTAssertEqual(StreamMenu.Item.stateText(true), "On"); XCTAssertEqual(StreamMenu.Item.stateText(false), "Off")
    }

    func testTheHeightsOfGenerationAreListedWithTheSavedOne() {
        let offered = GenerationState.heightChoices(offered: [720, 1080, 2160], chosen: 1080)
        XCTAssertEqual(offered.map(\.height), [720, 1080, 2160])
        XCTAssertEqual(offered.map(\.title), ["720p · faster", "1080p", "4K"])
        XCTAssertEqual(GenerationState.heightChoices(offered: [720], chosen: 540).map(\.title), ["540p", "720p · faster"])
    }

    func testAGenreIsNamedInWordsAndAGameKeepsItsColour() {
        XCTAssertEqual(Game.genreName("ACTION"), "Action")
        XCTAssertEqual(Game.genreName("ROLE_PLAYING_GAMES"), "Role-playing")
        XCTAssertEqual(Game.genreName("MUSIC_RHYTHM"), "Music Rhythm", "An unknown code is shown as written")
        func game(_ id: String, _ title: String) -> Game { Game(id: id, title: title, platform: "PS5", favorite: false, artworkURL: nil) }
        XCTAssertEqual(game("1", "Cyberpunk 2077").hue, 100)
        XCTAssertEqual(game("1", "DEMON'S SOULS").hue, 250)
        let own = game("PPSA01234", "Some Game").hue
        XCTAssertEqual(own, game("PPSA01234", "Renamed").hue, "The color follows the id, not the title")
        XCTAssertTrue((0..<360).contains(own))
        XCTAssertNotEqual(own, game("PPSA01235", "Some Game").hue)
    }
}
