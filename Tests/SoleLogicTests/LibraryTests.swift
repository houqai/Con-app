import XCTest
import SoleCloud
import SoleCore
@testable import SoleLogic

final class LibraryTests: XCTestCase {
    private func game(_ id: String, _ title: String, _ platform: String = "PS5", _ backend: CloudBackend = .ps5, favorite: Bool = false, concept: Int? = nil, product: String? = nil) -> Game {
        Game(id: id, title: title, platform: platform, favorite: favorite, artworkURL: nil, conceptID: concept, productID: product, cloudBackend: backend)
    }
    private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    func testTheHistoryOfACloudPlatformIsMadeOfGamesItsCatalogHas() {
        let history = [game("concept:1", "Cyberpunk 2077"), game("CUSA00900_00", "Bloodborne™", "PlayStation"),
                       game("CUSA00001_00", "Console Only", "PS4", .psPlusPC), game("CUSA00002_00", "The Last Guardian", "PS4", .psPlusPC),
                       game("NPUB00001_00", "Unknown Thing", "PlayStation"), game("CUSA00900_01", "Bloodborne", "PlayStation")]
        let catalog = [game("concept:1", "Cyberpunk 2077"), game("pc:UP9000-CUSA00900_00-BLOODBORNE000000", "Bloodborne™", "PS4", .psPlusPC),
                         game("pc:UP9000-CUSA03745_00-LASTGUARDIAN0000", "The Last Guardian™", "PS4", .psPlusPC), game("pc:UP0001-NPUB00002_00-OLDGAME000000000", "Old Game", "PS3", .ps3)]
        XCTAssertEqual(Library.recent(history, in: catalog, backend: .psPlusPC).map(\.id), ["pc:UP9000-CUSA00900_00-BLOODBORNE000000", "pc:UP9000-CUSA03745_00-LASTGUARDIAN0000"],
                       "The streamed game and the console game the cloud has, as the catalog's games, each once")
        XCTAssertEqual(Library.recent(history, in: catalog, backend: .ps5).map(\.id), ["concept:1", "NPUB00001_00"], "A game that belongs to the PS4 cloud is not listed with PS5")
        XCTAssertTrue(Library.recent(history, in: catalog, backend: .ps3).isEmpty)
        XCTAssertEqual(Library.recent(history, in: [], backend: .ps5).count, 4, "Until the catalogs are loaded the history is as PSN gives it")
    }

    func testAGameOfTheHistoryIsKnownByItsConceptAndListedOnce() throws {
        let titles: [PlayedTitle] = try decode(#"""
        [{"titleId":"PPSA01_00","name":"Cyber","localizedName":"Cyberpunk 2077","category":"ps5_native_game","concept":{"id":234567},"imageUrl":"https://image.api.playstation.com/a.png"},
         {"titleId":"CUSA02_00","name":"Cyberpunk 2077","category":"ps4_game","concept":{"id":234567}},
         {"titleId":"CUSA03_00","name":"Bloodborne","category":"ps4_game"},
         {"titleId":"NPUB04_00","name":"Streamed","category":"unknown"}]
        """#)
        let games = Library.games(history: titles, favorites: ["CUSA03_00", "concept:234567"])
        XCTAssertEqual(games.map(\.id), ["concept:234567", "CUSA03_00", "NPUB04_00"], "Two editions of one concept are one game")
        XCTAssertEqual(games.map(\.title), ["Cyberpunk 2077", "Bloodborne", "Streamed"])
        XCTAssertEqual(games.map(\.cloudBackend), [.ps5, .psPlusPC, .ps5])
        XCTAssertEqual(games.map(\.favorite), [true, true, false], "A favorite is kept by the concept or by the title")
        XCTAssertEqual(games[0].conceptID, 234567)
        XCTAssertNotNil(games[0].artworkURL)
    }

    func testThePlatformPSNNamesDecidesTheCloud() {
        XCTAssertEqual(Library.backend(platform: "PS5"), .ps5)
        XCTAssertEqual(Library.backend(platform: "PS4"), .psPlusPC)
        XCTAssertEqual(Library.backend(platform: "ps3"), .ps3)
        XCTAssertEqual(Library.backend(platform: "PS4 · PS5"), .ps5, "A game for both is the PS5 cloud's")
        XCTAssertEqual(Library.backend(platform: "PlayStation"), .ps5)
        XCTAssertEqual(Library.backend(platform: "PC"), .ps5)
    }

    func testGamesOfTheCatalogsCarryWhatAStartNeeds() throws {
        let title: CloudTitle = try decode(#"{"conceptId":10,"name":"Astro Bot","productId":"UP9000-PPSA01_00-ASTRO","genre":["Action"],"device":["PS4","PS5"]}"#)
        let ps5 = Library.game(title, favorites: ["concept:10"])
        XCTAssertEqual(ps5.id, "concept:10"); XCTAssertEqual(ps5.platform, "PS4 · PS5"); XCTAssertTrue(ps5.favorite)
        XCTAssertEqual(ps5.productID, "UP9000-PPSA01_00-ASTRO"); XCTAssertEqual(ps5.conceptID, 10); XCTAssertEqual(ps5.genres, ["Action"])
        XCTAssertEqual(ps5.cloudBackend, .ps5)
        XCTAssertEqual(ps5.storeURL?.absoluteString, "https://store.playstation.com/concept/10")
        XCTAssertEqual(Library.game(title, favorites: [], platform: "PS5").platform, "PS5")
        let bare: CloudTitle = try decode(#"{"conceptId":11,"name":"Bare"}"#)
        XCTAssertEqual(Library.game(bare, favorites: []).platform, "PS5", "A game without devices is a PS5 game")
    }

    func testThePartsOfTheLibraryAreNarrowedByPlatformSearchAndOwnership() {
        let catalog = [game("a", "Alpha", favorite: true), game("b", "Beta"), game("pc:c", "Gamma", "PS4", .psPlusPC, favorite: true), game("pc:d", "Alpha Old", "PS3", .ps3)]
        let history = [game("b", "Beta"), game("h", "Home", favorite: true)]
        func listed(_ filter: LibraryFilter, _ backend: CloudBackend = .ps5, search: String = "", owned: Set<String> = []) -> [String] {
            Library.listed(filter, backend: backend, search: search, catalog: catalog, history: history) { owned.contains($0.id) }.map(\.id)
        }
        XCTAssertEqual(listed(.all), ["a", "b"])
        XCTAssertEqual(listed(.all, .psPlusPC), ["pc:c"])
        XCTAssertEqual(listed(.all, .ps3), ["pc:d"])
        XCTAssertEqual(listed(.all, search: "ALP"), ["a"], "The search does not mind the case")
        XCTAssertEqual(listed(.owned, owned: ["b", "pc:c"]), ["b"])
        XCTAssertEqual(listed(.recent), ["b", "h"])
        XCTAssertEqual(listed(.favorites), ["a", "h"], "Favorites of the catalog and of the history")
        XCTAssertEqual(listed(.favorites, .psPlusPC), ["pc:c"])
        XCTAssertEqual(listed(.favorites, search: "home"), ["h"])
    }

    func testTheWholeCatalogOpensWithWellKnownGamesAndAPartKeepsItsOrder() {
        let games = [game("a", "Alan Wake"), game("c", "Cyberpunk 2077"), game("d", "Demon’s Souls"), game("z", "Zelda")]
        XCTAssertEqual(Library.ordered(games, filter: .all, search: "").map(\.id), ["d", "c", "a", "z"])
        XCTAssertEqual(Library.ordered(games, filter: .recent, search: "").map(\.id), ["a", "c", "d", "z"])
        XCTAssertEqual(Library.ordered(games, filter: .all, search: "a").map(\.id), ["a", "c", "d", "z"])
    }

    func testThePS3CloudHasNoPurchasesAndNoHistory() {
        XCTAssertEqual(Library.filters(for: .ps3), [.all, .favorites])
        XCTAssertEqual(Library.filters(for: .ps5), LibraryFilter.allCases)
        XCTAssertEqual(Library.filters(for: .psPlusPC), LibraryFilter.allCases)
        XCTAssertEqual(Library.filter(saved: "Recent", backend: "ps3"), .all, "The part that was open is not there on this platform")
        XCTAssertEqual(Library.filter(saved: "Favorites", backend: "ps3"), .favorites)
        XCTAssertEqual(Library.filter(saved: "Recent", backend: "psPlusPC"), .recent)
        XCTAssertEqual(Library.filter(saved: "Purchased", backend: nil), .owned)
        XCTAssertEqual(Library.filter(saved: nil, backend: nil), .all)
        XCTAssertEqual(Library.filter(saved: "something old", backend: "ps5"), .all)
    }

    func testAChosenGameIsStartedAsTheCatalogsOwnEntry() {
        let catalog = [game("concept:1", "Cyberpunk 2077", concept: 1, product: "UP-PPSA01_00-CP"), game("concept:2", "Other", concept: 2, product: "UP-PPSA02_00-OT"),
                         game("pc:UP-CUSA00900_00-BB", "Bloodborne™", "PS4", .psPlusPC, product: "UP-CUSA00900_00-BB")]
        let played = game("concept:1", "Cyberpunk 2077", concept: 1)
        XCTAssertEqual(Library.startable(played, in: catalog).productID, "UP-PPSA01_00-CP", "The history has no product; the catalog has")
        let other = game("PPSA02_00", "Other edition", concept: 2)
        XCTAssertEqual(Library.startable(other, in: catalog).id, "concept:2", "The same concept under another identifier")
        let streamed = game("CUSA00900_00", "Bloodborne", "PlayStation", .psPlusPC)
        XCTAssertEqual(Library.startable(streamed, in: catalog).id, "pc:UP-CUSA00900_00-BB", "The PS4 cloud knows a game by its name")
        let namesake = game("X", "Bloodborne")
        XCTAssertEqual(Library.startable(namesake, in: catalog).id, "X", "A PS5 game is never matched by name")
        XCTAssertFalse(Library.canStart(namesake))
        XCTAssertTrue(Library.canStart(played))
        XCTAssertTrue(Library.canStart(Library.startable(streamed, in: catalog)))
    }

    func testThePageOfAGameAndTheSameGameOnAnotherTab() {
        let catalog = [game("concept:1", "Resident Evil 2", concept: 1), game("pc:re2", "RESIDENT EVIL 2", "PS4", .psPlusPC, product: "UP-CUSA1-RE2"),
                         game("pc:re2old", "Resident Evil™ 2", "PS3", .ps3)]
        XCTAssertEqual(Library.page(for: game("h", "Resident Evil 2", "PlayStation", .psPlusPC), in: catalog).id, "pc:re2")
        XCTAssertEqual(Library.page(for: game("h", "Resident Evil 2"), in: catalog).id, "h", "A PS5 game opens as it is")
        XCTAssertEqual(Library.page(for: game("h", "Nothing", "PS4", .psPlusPC), in: catalog).id, "h")
        XCTAssertEqual(Library.elsewhere(catalog[0], in: catalog)?.id, "pc:re2", "The PS5 game refused for want of a license is in the PS4 cloud")
        XCTAssertEqual(Library.elsewhere(catalog[1], in: catalog)?.id, "pc:re2old")
        XCTAssertNil(Library.elsewhere(catalog[2], in: [catalog[0], catalog[2]]), "The PS5 cloud is not where a refused game is sent")
        XCTAssertNil(Library.elsewhere(game("x", "Alone"), in: catalog))
    }

    func testAGameIsTheAccountsByItsLicenseAndANameDoesNotCrossToARemake() {
        let owned = OwnedLibrary([.init(productID: "UP0102-CUSA09193_00-RE2", conceptID: nil, name: "Resident Evil 2"),
                                  .init(productID: "UP9000-PPSA01969_00-DEATHSTRANDINGUS", conceptID: 234585, name: "DEATH STRANDING DIRECTOR’S CUT")])
        let original = game("pc:UP0102-CUSA09193_00-RE2", "Resident Evil 2", "PS4", .psPlusPC, product: "UP0102-CUSA09193_00-RE2")
        let remake = game("concept:9", "Resident Evil 2", concept: 9, product: "UP0102-PPSA04000_00-RE2R")
        let strand = game("concept:234585", "Death Stranding", concept: 234585)
        let claimed = Library.ClaimedNames(owned, catalog: [original, remake, strand])
        XCTAssertTrue(Library.isOwned(original, by: owned, claimed: claimed))
        XCTAssertFalse(Library.isOwned(remake, by: owned, claimed: claimed), "The PS4 license is the PS4 game's; its name says nothing about the PS5 one")
        XCTAssertTrue(Library.isOwned(strand, by: owned, claimed: claimed), "By the concept")
        XCTAssertFalse(Library.isOwned(game("concept:5", "Unrelated", concept: 5), by: owned, claimed: claimed))
    }

    func testTheStoreIsAskedAboutTheAccountsOwnPlayedAndSearchedGames() throws {
        let unconfirmed: [CloudTitle] = try decode(#"""
        [{"conceptId":1,"name":"Zeta Owned","productId":"UP-PPSA01_00-Z"},{"conceptId":2,"name":"Played Lately"},
         {"conceptId":3,"name":"Searched Thing"},{"conceptId":4,"name":"Nobody Asked"},{"conceptId":5,"name":"A Searched Other"}]
        """#)
        let owned = OwnedLibrary([.init(productID: "UP-PPSA01_00-Z", conceptID: nil, name: nil)])
        let history = [game("h", "Played Lately™")]
        XCTAssertEqual(Library.streamingCandidates(unconfirmed, owned: owned, history: history, query: "").map(\.conceptId), [2, 1], "By name")
        XCTAssertEqual(Library.streamingCandidates(unconfirmed, owned: owned, history: history, query: "searched").map(\.conceptId), [5, 3, 2, 1], "What the search names is asked first")
        XCTAssertTrue(Library.streamingCandidates(unconfirmed, owned: OwnedLibrary(), history: [], query: "").isEmpty)
    }

    func testTheCloudsOfOlderConsolesReplaceTheirPartOfTheCatalog() {
        let before = [game("concept:2", "Beta"), game("pc:old", "Old", "PS4", .psPlusPC), game("concept:1", "Alpha")]
        XCTAssertEqual(Library.catalog(before, replacingStreamed: [], favorites: []).map(\.id), ["concept:1", "concept:2"], "Sorted by title; the old PS4 games are gone")
    }

    func testAHeightStartsFromItsBitrateAndOlderCloudsStreamLower() {
        XCTAssertEqual(StreamQuality.heights.map(StreamQuality.bitrate), [5, 8, 10, 30, 40, 50])
        XCTAssertEqual(StreamQuality.bitrate(height: 900), 30)
        XCTAssertEqual(StreamQuality.height(2160, for: .ps5), 2160)
        XCTAssertEqual(StreamQuality.height(2160, for: .psPlusPC), 1080)
        XCTAssertEqual(StreamQuality.height(2160, for: .ps3), 720)
        XCTAssertEqual(StreamQuality.height(540, for: .ps3), 540)
        XCTAssertEqual(StreamQuality.heights, CloudSessionService.widths.keys.sorted(), "Every height of the settings can be asked of Sony")
        XCTAssertEqual([CloudBackend.ps5, .psPlusPC, .ps3].map(\.console), ["PS5", "PS4", "PS3"])
    }
}
