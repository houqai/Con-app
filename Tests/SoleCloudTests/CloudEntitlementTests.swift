import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SoleCloud

private func changed(_ row: [String: Any], _ changes: [String: Any]) -> [String: Any] {
    row.merging(changes) { $1 }
}

final class CloudEntitlementTests: XCTestCase {
    func testTokenCallbackChecksDestinationStateAndDuplicates() throws {
        let base = CloudEntitlementService.redirect
        XCTAssertEqual(try CloudEntitlementService.token(from: URL(string: base + "#access_token=test-token&state=expected")!, expectedState: "expected"), "test-token")
        for url in [base + "#access_token=a&state=wrong", base + "#access_token=a&access_token=b&state=expected", base + "?state=expected#access_token=a&state=expected", "https://example.com/#access_token=a&state=expected", base + "#access_token=a%0D%0A&state=expected"] {
            XCTAssertThrowsError(try CloudEntitlementService.token(from: URL(string: url)!, expectedState: "expected"), url)
        }
    }
    func testChoosesOnlyActiveLicenseForExactProduct() {
        let rows: [[String: Any]] = [
            ["product_id": "PRODUCT", "id": "expired", "active_flag": false, "feature_type": 3, "license_type": 4],
            ["product_id": "OTHER", "id": "other-stream", "active_flag": true, "feature_type": 3, "license_type": 4],
            ["product_id": "PRODUCT", "id": "full-game", "active_flag": true, "feature_type": 3],
            ["product_id": "PRODUCT", "id": "stream-game", "active_flag": true, "feature_type": 3, "license_type": 4]
        ]
        XCTAssertEqual(CloudEntitlementService.select(rows, productID: "PRODUCT"), "stream-game")
        XCTAssertNil(CloudEntitlementService.select(rows, productID: "MISSING"))
        XCTAssertNil(CloudEntitlementService.select([["product_id": "PRODUCT", "id": "../invalid", "active_flag": true, "feature_type": 3]], productID: "PRODUCT"))
    }
    func testMatchesOwnedPS5EditionByConceptWithoutSelectingPS4DLCOrExpiredLicense() {
        let rows: [[String: Any]] = [
            ["product_id": "EP0001-CUSA12345_00-GAME", "id": "ps4", "active_flag": true, "feature_type": 3, "game_meta": ["concept_id": "100"]],
            ["product_id": "EP0001-PPSA12345_00-DLC", "id": "dlc", "active_flag": true, "feature_type": 0, "game_meta": ["concept_id": "100"]],
            ["product_id": "EP0001-PPSA12345_00-EXPIRED", "id": "expired", "active_flag": false, "feature_type": 3, "game_meta": ["concept_id": "100"]],
            ["product_id": "EP0001-PPSA12345_00-EDITION", "id": "owned-ps5", "active_flag": true, "feature_type": 3, "game_meta": ["concept_id": "100"]]
        ]
        XCTAssertEqual(CloudEntitlementService.select(rows, productID: "US-CATALOG", conceptID: 100), "owned-ps5")
        XCTAssertEqual(CloudEntitlementService.select(rows, productID: nil, conceptID: 100), "owned-ps5")
        XCTAssertNil(CloudEntitlementService.select(rows, productID: nil))
        XCTAssertNil(CloudEntitlementService.select(rows, productID: "US-CATALOG", conceptID: 101))
        XCTAssertNil(CloudEntitlementService.select(rows, productID: "US-CATALOG"))
        XCTAssertNil(CloudEntitlementService.select(Array(rows.prefix(3)), productID: "US-CATALOG", conceptID: 100))
    }

    func testCrossGenerationPurchaseUsesOwnedPS5ProductInsteadOfPS4Entitlement() {
        let product = "UP4497-PPSA03974_00-0000000000000CP1"
        let row: [String: Any] = ["product_id": product,
            "id": "UP4497-CUSA16596_00-0000000000000004", "active_flag": true,
            "feature_type": 3, "game_meta": ["package_type": "PS4GD"]]
        XCTAssertEqual(CloudEntitlementService.select([row], productID: product), product)
        XCTAssertNil(CloudEntitlementService.select([changed(row, ["active_flag": false])], productID: product))
    }

    func testNativePS5LicenseWinsOverCrossGenerationProduct() {
        let product = "UP0001-PPSA01876_00-FC6EDSTANDARD000"
        let ps4: [String: Any] = ["product_id": product, "id": "UP0001-CUSA15717_00-FARCRY6GAME00000", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PS4GD"]]
        let ps5: [String: Any] = ["product_id": product, "id": "UP0001-PPSA01876_00-FARCRY6GAME00000", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]]
        XCTAssertEqual(CloudEntitlementService.select([ps4, ps5], productID: product), ps5["id"] as? String)
        XCTAssertEqual(CloudEntitlementService.select([ps5, ps4], productID: product), ps5["id"] as? String)
        XCTAssertEqual(CloudEntitlementService.select([ps4, changed(ps5, ["active_flag": false])], productID: product), product)
    }

    func testResolveDoesNotStopAtPS4CompanionOnEarlierPage() async throws {
        let product = "UP0001-PPSA01876_00-FC6EDSTANDARD000"
        let ps4: [String: Any] = ["product_id": product, "id": "UP0001-CUSA15717_00-FARCRY6GAME00000", "active_flag": true, "feature_type": 3]
        let ps5: [String: Any] = ["product_id": product, "id": "UP0001-PPSA01876_00-FARCRY6GAME00000", "active_flag": true, "feature_type": 3]
        let fillers: [[String: Any]] = (0..<299).map { ["id": "filler-\($0)", "product_id": "unrelated", "active_flag": false, "feature_type": 3] }
        let first = try JSONSerialization.data(withJSONObject: ["entitlements": [ps4] + fillers])
        let second = try JSONSerialization.data(withJSONObject: ["entitlements": [ps5]])
        EntitlementPageStub.handler = { request in
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "start" }?.value
            XCTAssertEqual(request.url?.host, "commerce.api.np.km.playstation.net")
            XCTAssertTrue(start == "0" || start == "300")
            return start == "0" ? first : second
        }
        defer { EntitlementPageStub.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EntitlementPageStub.self]
        let service = CloudEntitlementService(session: URLSession(configuration: configuration))
        let selected = try await service.resolve(productID: product, token: "test-token")
        XCTAssertEqual(selected, ps5["id"] as? String)
    }

    func testNativeLicenseInOtherEditionWinsOverExactPS4CompanionByEveryIdentityRule() {
        let wanted = "UP0001-PPSA12345_00-BUNDLE", native = "UP0001-PPSA12345_00-BASEGAME"
        let companion: [String: Any] = ["product_id": wanted, "id": "UP0001-CUSA12345_00-BASEGAME", "active_flag": true, "feature_type": 3]
        let owned: [String: Any] = ["product_id": native, "id": native, "active_flag": true, "feature_type": 3]
        for rows in [[companion, owned], [owned, companion]] {
            XCTAssertEqual(CloudEntitlementService.selection(rows, productID: wanted), native, "Same title beats the bundle product inferred from PS4")
        }
        let edition = "UP0001-PPSA67890_00-PLUSEDITION"
        let related: [String: Any] = ["product_id": edition, "id": edition, "active_flag": true, "feature_type": 3, "concept_id": 123]
        for rows in [[companion, related], [related, companion]] {
            XCTAssertEqual(CloudEntitlementService.selection(rows, productID: wanted, conceptID: 123), edition)
            XCTAssertEqual(CloudEntitlementService.selection(rows, productID: wanted, products: [wanted, edition]), edition)
            XCTAssertEqual(CloudEntitlementService.selection(rows, productID: wanted), wanted, "No unrelated native license is substituted")
        }
    }

    func testStreamingLicensePriorityIsSharedByExactConceptEditionAndTitleMatching() {
        let product = "UP0001-PPSA12345_00-BASEGAME", stream = "UP0001-PPSA12345_00-PSRSVD0000000000"
        let game: [String: Any] = ["product_id": product, "id": product, "active_flag": true, "feature_type": 3, "concept_id": 123, "game_meta": ["package_type": "PSGD"]]
        let reserved: [String: Any] = ["product_id": product, "id": stream, "active_flag": true, "feature_type": 3, "concept_id": 123, "game_meta": ["package_type": "PSGS"]]
        for rows in [[game, reserved], [reserved, game]] {
            XCTAssertEqual(CloudEntitlementService.select(rows, productID: product), stream)
            XCTAssertEqual(CloudEntitlementService.select(rows, productID: "OTHER", conceptID: 123), stream)
            XCTAssertEqual(CloudEntitlementService.selectEdition(rows, products: [product]), stream)
            XCTAssertEqual(CloudEntitlementService.selectSameTitle(rows, productID: "UP0001-PPSA12345_00-DELUXE"), stream)
        }
    }

    func testFullGameSelectionIgnoresAddOnsTrackingAndExpiredNativeLicenses() {
        let product = "UP0001-PPSA12345_00-BUNDLE", game = "UP0001-PPSA12345_00-BASEGAME"
        let row: [String: Any] = ["product_id": product, "id": game, "active_flag": true, "feature_type": 3]
        let invalid = [changed(row, ["id": "UP0001-PPSA12345_00-ADDON", "feature_type": 1]),
                       changed(row, ["id": "UP0001-PPSA12345_00-PSTRACK000000000", "feature_type": 0]),
                       changed(row, ["active_flag": false])]
        XCTAssertNil(CloudEntitlementService.selection(invalid, productID: product, products: [product]))
        for index in 0...invalid.count {
            var rows = invalid; rows.insert(row, at: index)
            XCTAssertEqual(CloudEntitlementService.selection(rows, productID: product, products: [product]), game)
        }
    }

    func testPS4OnlyLicenseCannotBeUsedForPS5Cloud() {
        let row: [String: Any] = ["product_id": "UP0001-CUSA00001_00-GAME", "id": "UP0001-CUSA00001_00-GAME", "active_flag": true, "feature_type": 3]
        XCTAssertNil(CloudEntitlementService.select([row], productID: "UP0001-CUSA00001_00-GAME"))
    }

    func testLibraryListsOnlyActiveWholeGamesThePS5CloudCanStart() {
        let rows: [[String: Any]] = [
            ["product_id": "UP9000-PPSA01342_00-DEMONSSOULS00000", "id": "UP9000-PPSA01342_00-DEMONSSOULS00000", "active_flag": true, "feature_type": 3, "game_meta": ["name": "Demon's Souls", "package_type": "PSGD"]],
            ["product_id": "UP4497-PPSA03974_00-0000000000000CP1", "id": "UP4497-CUSA16596_00-0000000000000004", "active_flag": true, "feature_type": 3, "game_meta": ["name": "Cyberpunk 2077", "package_type": "PS4GD", "concept_id": "234567"]],
            ["product_id": "UP0001-PPSA00002_00-ADDON", "id": "UP0001-PPSA00002_00-ADDON", "active_flag": true, "feature_type": 1, "game_meta": ["name": "Add-on", "package_type": "PSAC"]],
            ["product_id": "UP0001-PPSA00003_00-EXPIRED", "id": "UP0001-PPSA00003_00-EXPIRED", "active_flag": false, "feature_type": 3, "game_meta": ["name": "Expired"]],
            ["product_id": "UP0001-CUSA00004_00-PS4ONLY", "id": "UP0001-CUSA00004_00-PS4ONLY", "active_flag": true, "feature_type": 3, "game_meta": ["name": "PS4 only"]],
            ["product_id": "bad id?", "id": "UP0001-PPSA00005_00-X", "active_flag": true, "feature_type": 3],
            ["product_id": "UP0001-PPSA00006_00-BYPACKAGE", "id": "UP0001-PPSA00006_00-BYPACKAGE", "active_flag": true, "feature_type": 0, "game_meta": ["package_type": "PSGD", "conceptId": 77]]
        ]
        XCTAssertEqual(CloudEntitlementService.owned(rows), [
            .init(productID: "UP9000-PPSA01342_00-DEMONSSOULS00000", name: "Demon's Souls"),
            .init(productID: "UP4497-PPSA03974_00-0000000000000CP1", licenseID: "UP4497-CUSA16596_00-0000000000000004", conceptID: 234567, name: "Cyberpunk 2077"),
            .init(productID: "UP0001-PPSA00006_00-BYPACKAGE", conceptID: 77)
        ])
        XCTAssertEqual(CloudEntitlementService.owned([], includePS4: true), [])
        XCTAssertEqual(CloudEntitlementService.owned(rows, includePS4: true).count, 4)
        XCTAssertEqual(CloudEntitlementService.owned([]), [])
    }

    func testStoreLinksPlusEditionButDoesNotSubstituteLegendsOrUnrelatedConcept() throws {
        let retail = "UP9000-PPSA02225_00-GHOSTDIRECTORPS5"
        let plus = "UP9000-PPSA05030_00-GHOSTDCPS5PSPLUS"
        let legends = "UP9000-PPSA02225_00-GHOSTSHIP0000000"
        var cache: [String: Any] = ["Concept:235227": ["products": [retail, plus, legends].map { ["__ref": "Product:" + $0] }]]
        for (id, name) in [(retail, "Ghost of Tsushima DIRECTOR’S CUT"), (plus, "Ghost of Tsushima DIRECTOR’S CUT (PlayStation Plus)"), (legends, "Ghost of Tsushima: Legends")] {
            cache["Product:" + id] = ["id": id, "name": name, "platforms": ["PS5"], "storeDisplayClassification": "FULL_GAME"]
        }
        let json = try JSONSerialization.data(withJSONObject: ["cache": cache])
        let html = Data(("<script type=\"application/json\">" + String(decoding: json, as: UTF8.self) + "</script>").utf8)
        let products = CloudEntitlementService.storeEditions(html, conceptID: 235227, productID: retail)
        XCTAssertEqual(products, [retail, plus])
        XCTAssertTrue(CloudEntitlementService.storeEditions(html, conceptID: 999, productID: retail).isEmpty)
        XCTAssertTrue(CloudEntitlementService.storeEditions(html, conceptID: 235227, productID: "UNRELATED").isEmpty)
        let rows: [[String: Any]] = [
            ["product_id": plus, "id": "UP9000-CUSA32708_00-GHOSTSHIP0000000", "active_flag": true, "feature_type": 3],
            ["product_id": plus, "id": "UP9000-PPSA05030_00-GHOSTSHIP0000000", "active_flag": true, "feature_type": 3]
        ]
        XCTAssertEqual(CloudEntitlementService.selectEdition(rows, products: products), "UP9000-PPSA05030_00-GHOSTSHIP0000000")
        XCTAssertNil(CloudEntitlementService.selectEdition(rows.map { changed($0, ["active_flag": false]) }, products: products))
        XCTAssertNil(CloudEntitlementService.selectEdition(rows.map { changed($0, ["feature_type": 1]) }, products: products))
    }

    func testStoreLinksThePlainGameAndItsDeluxeEditionOfOneTitle() throws {
        let deluxe = "UP9000-PPSA01969_00-DEATHSTRADCDDE01", plain = "UP9000-PPSA01969_00-DEATHSTRANDINGUS"
        let ps4 = "UP9000-CUSA11260_00-DEATHSTRAND00001", ps4Deluxe = "UP9000-CUSA11260_00-DEATHSTRANDELUXE"
        var cache: [String: Any] = [:]
        for (id, name, kind, platform) in [(deluxe, "DEATH STRANDING DIRECTOR’S CUT Digital Deluxe Edition", "PREMIUM_EDITION", "PS5"), (ps4Deluxe, "DEATH STRANDING Digital Deluxe Edition", "FULL_GAME", "PS4"),
                                           (ps4, "DEATH STRANDING", "FULL_GAME", "PS4"), (plain, "DEATH STRANDING DIRECTOR’S CUT", "FULL_GAME", "PS5")] {
            cache["Product:" + id] = ["id": id, "name": name, "platforms": [platform], "storeDisplayClassification": kind]
        }
        let mode = "UP9000-PPSA01969_00-DEATHSTRANDMODE0", other = "UP9000-PPSA07777_00-DEATHSTRANDOTHER"
        cache["Product:" + mode] = ["id": mode, "name": "DEATH STRANDING DIRECTOR’S CUT: Racing", "platforms": ["PS5"], "storeDisplayClassification": "FULL_GAME"]
        cache["Product:" + other] = ["id": other, "name": "DEATH STRANDING DIRECTOR’S CUT Ultimate Edition", "platforms": ["PS5"], "storeDisplayClassification": "FULL_GAME"]
        cache["Concept:234585"] = ["defaultProduct": ["__ref": "Product:" + deluxe], "products": [deluxe, ps4Deluxe, ps4, plain, mode, other].map { ["__ref": "Product:" + $0] }]
        let json = try JSONSerialization.data(withJSONObject: ["cache": cache])
        let html = Data(("<script type=\"application/json\">" + String(decoding: json, as: UTF8.self) + "</script>").utf8)
        XCTAssertEqual(CloudEntitlementService.storeEditions(html, conceptID: 234585, productID: deluxe), [deluxe, plain])
        XCTAssertEqual(CloudEntitlementService.storeEditions(html, conceptID: 234585, productID: nil), [deluxe, plain], "The default product when none is named")
        XCTAssertEqual(CloudEntitlementService.storeEditions(html, conceptID: 234585, productID: plain), [deluxe, plain], "Holding the deluxe edition is holding the game")
        let rows: [[String: Any]] = [
            ["product_id": ps4, "id": ps4, "active_flag": true, "feature_type": 3, "game_meta": ["name": "DEATH STRANDING", "package_type": "PS4GD"]],
            ["product_id": plain, "id": plain, "active_flag": true, "feature_type": 3, "game_meta": ["name": "DEATH STRANDING DIRECTOR'S CUT", "package_type": "PSGD"]],
            ["product_id": plain, "id": "UP9000-PPSA01969_00-PSTRACK000000000", "active_flag": true, "feature_type": 0, "game_meta": ["name": "Death Stranding Director's Cut", "package_type": "PSTRACK"]],
            ["product_id": ps4, "id": "UP9000-CUSA11260_00-PSRSVD0000000000", "active_flag": true, "feature_type": 3, "game_meta": ["name": "DEATH STRANDING", "package_type": "PS4GS"]]
        ]
        XCTAssertNil(CloudEntitlementService.select(rows, productID: deluxe, conceptID: 234585), "The licenses carry no concept")
        XCTAssertEqual(CloudEntitlementService.selectEdition(rows, products: CloudEntitlementService.storeEditions(html, conceptID: 234585, productID: deluxe)), plain)
        XCTAssertNil(CloudEntitlementService.selectEdition(Array(rows.prefix(1)) + Array(rows.suffix(2)), products: [deluxe, plain]), "A PS4 license and a tracking row are not the PS5 game")
        XCTAssertEqual(CloudEntitlementService.titleID(plain), "PPSA01969_00")
        XCTAssertNil(CloudEntitlementService.titleID("PRODUCT"))
    }

    func testFindsAGameByTheIdentifierOfItsLicenseWhenTheProductIsABundleOrAnotherEdition() {
        let bundle = "UB0046-PPSA24602_00-0388055963388374"
        let rows: [[String: Any]] = [
            ["product_id": bundle, "id": "UB0046-CUSA43979_00-STALKERCOP000000", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PS4GD"]],
            ["product_id": bundle, "id": "UB0046-PPSA24600_00-0528451001987257", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]],
            ["product_id": bundle, "id": "UB0046-PPSA24601_00-0688906713281357", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]],
            ["product_id": "UP9000-PPSA30630_00-MLBTHESHOW26PLUS", "id": "UP9000-PPSA30630_00-MLBTHESHOW26SHIP", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]],
            ["product_id": "UP0751-CUSA14150_00-HUMANITYGAME0000", "id": "UP0751-PPSA03771_00-HUMANITYGAME0001", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]],
            ["product_id": "UP0751-CUSA14150_00-HUMANITYGAME0000", "id": "UP0751-CUSA14150_00-HUMANITYGAME0000", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PS4GD"]]
        ]
        for asked in ["UB0046-PPSA24600_00-0528451001987257", "UB0046-PPSA24601_00-0688906713281357", "UP9000-PPSA30630_00-MLBTHESHOW26SHIP", "UP0751-PPSA03771_00-HUMANITYGAME0001"] {
            XCTAssertEqual(CloudEntitlementService.select(rows, productID: asked), asked)
            XCTAssertNil(CloudEntitlementService.select(rows.map { changed($0, ["active_flag": false]) }, productID: asked))
        }
        XCTAssertNil(CloudEntitlementService.select(Array(rows.suffix(1)), productID: "UP0751-CUSA14150_00-HUMANITYGAME0000"), "A PS4 license alone does not start in the PS5 cloud")
    }

    func testTakesAnotherLicenseForTheWholeGameOfTheSameTitleAsTheLastResort() {
        let rows: [[String: Any]] = [
            ["product_id": "UP1003-PPSA02017_00-OSPREYGAMECLIENT", "id": "UP1003-PPSA02017_00-OSPREYGAMECLIENT", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]],
            ["product_id": "UP0001-PPSA01396_00-RB6SIEGEELITEY10", "id": "UP0001-CUSA01800_00-RAINBOWSIXSIEGE0", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PS4GD"]],
            ["product_id": "UP0001-PPSA01396_00-RB6SIEGEELITEY10", "id": "UP0001-CUSA01800_00-RB6SIEGESPYR1OPS", "active_flag": true, "feature_type": 0, "game_meta": ["package_type": "PS4AC"]],
            ["product_id": "UP0001-PPSA01396_00-RB6SIEGEELITEY10", "id": "UP0001-PPSA01396_00-RAINBOWSIXSIEGE0", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PSGD"]],
            ["product_id": "UP9000-CUSA08966_00-DAYSGONECOMPLETE", "id": "UP9000-CUSA08966_00-DAYSGONECOMPLETE", "active_flag": true, "feature_type": 3, "game_meta": ["package_type": "PS4GD"]],
            ["product_id": "UP0001-PPSA09999_00-SEASONPASS000000", "id": "UP0001-PPSA09999_00-SEASONPASS000000", "active_flag": true, "feature_type": 0, "game_meta": ["package_type": "PSAC"]]
        ]
        XCTAssertEqual(CloudEntitlementService.selectSameTitle(rows, productID: "UP1003-PPSA02017_00-ESOMORROWINDBUND"), "UP1003-PPSA02017_00-OSPREYGAMECLIENT")
        XCTAssertEqual(CloudEntitlementService.selectSameTitle(rows, productID: "UP0001-PPSA01396_00-R6SIEGEFREEACESS"), "UP0001-PPSA01396_00-RAINBOWSIXSIEGE0", "The PS5 license, not the PS4 one or the add-on")
        XCTAssertNil(CloudEntitlementService.selectSameTitle(rows, productID: "UP9000-PPSA28180_00-DAYSGONEREMASTER"), "The PS4 game is another title")
        XCTAssertNil(CloudEntitlementService.selectSameTitle(rows, productID: "UP0001-PPSA09999_00-THEGAME000000000"), "An add-on is not the game")
        XCTAssertNil(CloudEntitlementService.selectSameTitle(rows.map { changed($0, ["active_flag": false]) }, productID: "UP1003-PPSA02017_00-ESOMORROWINDBUND"))
        XCTAssertNil(CloudEntitlementService.selectSameTitle(rows, productID: "UP9000-CUSA08966_00-DAYSGONECOMPLETE"), "Only for the PS5 cloud")
        XCTAssertNil(CloudEntitlementService.selectSameTitle(rows, productID: nil))
    }

    func testRejectsMalformedPagesAndInjectedProductIDs() throws {
        XCTAssertThrowsError(try CloudEntitlementService.rows(Data("{}".utf8)))
        XCTAssertThrowsError(try CloudEntitlementService.rows(Data("{\"entitlements\":[1]}".utf8)))
        XCTAssertEqual(try CloudEntitlementService.rows(Data("{\"entitlements\":[]}".utf8)).count, 0)
        XCTAssertFalse(CloudEntitlementService.validID("product?scope=x"))
        XCTAssertFalse(CloudEntitlementService.validID("../product"))
    }
}

private final class EntitlementPageStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
