import XCTest
@testable import SoleCloud

final class OwnedLibraryTests: XCTestCase {
    private let library = OwnedLibrary([
        .init(productID: "UP9000-PPSA01342_00-DEMONSSOULS00000", name: "Demon's Souls"),
        .init(productID: "EP4497-PPSA03974_00-0000000000000CP1", conceptID: 234567, name: "Cyberpunk 2077"),
        .init(productID: "EP0006-PPSA01234_00-EDITION", name: "Assassin's Creed® Valhalla PS4 & PS5"),
        .init(productID: "UP0001-PPSA00009_00-NONAME")
    ])

    func testFindsAnEntryByProductConceptOrName() {
        XCTAssertTrue(library.contains(productID: "UP9000-PPSA01342_00-DEMONSSOULS00000", conceptID: 10000368, title: "anything"))
        XCTAssertTrue(library.contains(productID: "UP4497-PPSA03974_00-0000000000000CP1", conceptID: 234567, title: "other name"), "another region's product, same concept")
        XCTAssertTrue(library.contains(productID: "UP0006-PPSA09999_00-OTHER", conceptID: 5, title: "Assassin’s Creed Valhalla"), "another edition, same name")
        XCTAssertTrue(library.contains(productID: nil, conceptID: nil, title: "DEMON'S SOULS™"))
    }
    func testDoesNotClaimWhatIsNotOwned() {
        XCTAssertFalse(library.contains(productID: "UP0001-PPSA00001_00-OTHER", conceptID: 1, title: "Demon's Souls II"))
        XCTAssertFalse(library.contains(productID: nil, conceptID: nil, title: "Cyberpunk"))
        XCTAssertFalse(library.contains(productID: nil, conceptID: nil, title: ""))
        XCTAssertFalse(OwnedLibrary().contains(productID: "UP9000-PPSA01342_00-DEMONSSOULS00000", conceptID: 1, title: "Demon's Souls"))
        XCTAssertTrue(OwnedLibrary().isEmpty)
        XCTAssertFalse(library.isEmpty)
    }
    func testShortNamesAreNotMatchedByNameAlone() {
        let short = OwnedLibrary([.init(productID: "UP0001-PPSA00010_00-X", name: "Go")])
        XCTAssertFalse(short.contains(productID: nil, conceptID: nil, title: "Go"))
        XCTAssertTrue(short.contains(productID: "UP0001-PPSA00010_00-X", conceptID: nil, title: "Go"))
    }
    func testSurvivesStoring() throws {
        let copy = try JSONDecoder().decode(OwnedLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(copy, library)
    }

    private let mixed = OwnedLibrary([
        .init(productID: "UP9000-CUSA08966_00-DAYSGONECOMPLETE", name: "DAYS GONE"),
        .init(productID: "UP0102-PPSA07813_00-CLASSICRE2000001", licenseID: "UP0102-PPSA07813_00-SLUS007480000000", name: "Resident Evil 2"),
        .init(productID: "UP0102-PPSA07813_00-CLASSICRE2000001", licenseID: "UP0102-CUSA33878_00-SLUS007480000000", name: "Resident Evil 2"),
        .init(productID: "UB0046-PPSA24602_00-0388055963388374", licenseID: "UB0046-PPSA24600_00-0528451001987257", name: "S.T.A.L.K.E.R.: Call of Prypiat"),
        .init(productID: "UP9000-PPSA01969_00-DEATHSTRANDINGUS", name: "DEATH STRANDING DIRECTOR'S CUT"),
        .init(productID: "UP9000-PPSA05030_00-GHOSTDCPS5PSPLUS", licenseID: "UP9000-PPSA05030_00-GHOSTSHIP0000000", name: "Ghost of Tsushima DIRECTOR'S CUT"),
        .init(productID: "UP9000-PPSA05030_00-GHOSTDCPS5PSPLUS", licenseID: "UP9000-CUSA32708_00-GHOSTSHIP0000000", name: "Ghost of Tsushima DIRECTOR'S CUT"),
        .init(productID: "UP9000-CUSA11227_00-MEDIEVILHD000001", name: "MediEvil"),
        .init(productID: "UP0001-CUSA07777_00-OLDGAME000000000", name: "Old Game")
    ])
    private let catalog = ["UP9000-PPSA28180_00-DAYSGONEREMASTER", "UP9000-CUSA08966_00-DAYSGONECOMPLETE", "UP0102-PPSA07813_00-CLASSICRE2000001",
                             "UP0102-PPSA04288_00-BH2R000000000001", "UP0102-CUSA33878_00-CLASSICRE2000001", "UB0046-PPSA24600_00-0528451001987257",
                             "UP9000-PPSA01969_00-DEATHSTRADCDDE01", "UP9000-PPSA02225_00-GHOSTDIRECTORPS5", "UP0001-PPSA08888_00-OLDGAMEREMASTER0",
                             "UP9000-CUSA32708_00-GHOSTSHIP0000000", "UP9000-CUSA11227_00-MEDIEVILHD000001", "UP9000-CUSA42759_00-SCUS942270000000", "UP9000-PPSA15811_00-SCUS942270000000"]

    func testHoldsAGameByItsLicenseOrByAnotherProductOfTheSameTitle() {
        XCTAssertTrue(mixed.holds(productID: "UB0046-PPSA24600_00-0528451001987257", conceptID: nil), "The game inside a bundle, by its license")
        XCTAssertTrue(mixed.holds(productID: "UP9000-PPSA01969_00-DEATHSTRADCDDE01", conceptID: nil), "Another edition of the same title")
        XCTAssertTrue(mixed.holds(productID: "UP0102-CUSA33878_00-CLASSICRE2000001", conceptID: nil), "The PS4 game that came with the PS5 one")
        XCTAssertFalse(mixed.holds(productID: "UP9000-PPSA28180_00-DAYSGONEREMASTER", conceptID: nil))
        XCTAssertFalse(mixed.holds(productID: nil, conceptID: nil))
    }

    func testANameDoesNotMakeAnotherGameOfTheCatalogueOwned() {
        let claimed = (ps5: mixed.claimedNames(by: catalog, ps5: true), other: mixed.claimedNames(by: catalog, ps5: false))
        func owned(_ product: String, _ title: String, ps5: Bool) -> Bool { mixed.contains(productID: product, conceptID: nil, title: title, claimed: ps5 ? claimed.ps5 : claimed.other, ps5: ps5) }
        XCTAssertTrue(owned("UP9000-CUSA08966_00-DAYSGONECOMPLETE", "Days Gone", ps5: false))
        XCTAssertFalse(owned("UP9000-PPSA28180_00-DAYSGONEREMASTER", "DAYS GONE", ps5: true), "The PS5 remaster of a game held for PS4")
        XCTAssertTrue(owned("UP0102-PPSA07813_00-CLASSICRE2000001", "Resident Evil 2", ps5: true))
        XCTAssertFalse(owned("UP0102-PPSA04288_00-BH2R000000000001", "RESIDENT EVIL 2", ps5: true), "Owning the classic does not make the remake owned")
        XCTAssertTrue(owned("UP9000-PPSA02225_00-GHOSTDIRECTORPS5", "Ghost of Tsushima DIRECTOR’S CUT", ps5: true), "Matched by name; owning the PS4 version in the catalog does not block the match")
        XCTAssertTrue(owned("UP9000-CUSA32708_00-GHOSTSHIP0000000", "(PlayStation Plus) Ghost of Tsushima DIRECTOR’S CUT", ps5: false))
        XCTAssertTrue(owned("UP9000-CUSA11227_00-MEDIEVILHD000001", "MediEvil", ps5: false))
        XCTAssertFalse(owned("UP9000-CUSA42759_00-SCUS942270000000", "MediEvil", ps5: false), "Owning the remake does not make the classic owned on the PS4 tab")
        XCTAssertFalse(owned("UP9000-PPSA15811_00-SCUS942270000000", "MediEvil", ps5: true), "Nor on the PS5 tab, where the license is PS4-only")
        XCTAssertFalse(owned("UP0001-PPSA08888_00-OLDGAMEREMASTER0", "Old Game", ps5: true), "A PS4-only license, even if the PS4 cloud lacks the game")
        XCTAssertTrue(owned("UP0001-CUSA09999_00-OLDGAME000000000", "Old Game", ps5: false), "On the PS4 tab another product with the same name still matches")
        XCTAssertTrue(mixed.contains(productID: "UP0102-PPSA04288_00-BH2R000000000001", conceptID: nil, title: "RESIDENT EVIL 2"))
    }

    func testALibraryStoredByAnEarlierVersionStillAnswers() throws {
        let old = Data(#"{"products":["UP9000-PPSA01342_00-DEMONSSOULS00000"],"concepts":[234567],"names":["demonssouls"]}"#.utf8)
        let stored = try JSONDecoder().decode(OwnedLibrary.self, from: old)
        XCTAssertTrue(stored.contains(productID: "UP9000-PPSA01342_00-DEMONSSOULS00000", conceptID: nil, title: "x"))
        XCTAssertTrue(stored.contains(productID: nil, conceptID: nil, title: "Demon's Souls", ps5: true))
        XCTAssertTrue(stored.contains(productID: nil, conceptID: 234567, title: "x"))
    }
}
