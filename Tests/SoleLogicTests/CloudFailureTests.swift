import XCTest
import SoleCloud
import SoleCore
import SoleEngine
@testable import SoleLogic

final class CloudFailureTests: XCTestCase {
    func testIncompleteProbeIsNotReportedAsSilentServers() {
        let failure = CloudFailure(CloudDatacenter.Failure.probeTimeout)
        XCTAssertTrue(failure.canRetry)
        XCTAssertNotEqual(failure.message, CloudFailure(CloudDatacenter.Failure.unreachable).message)
    }

    private func english(_ key: String, _ values: Any...) -> String { Localization.text(key, values: values, in: .english) }

    func testARequestThatIsWrongInItselfIsNotOfferedAgain() {
        XCTAssertTrue(CloudFailure(CloudProtocol.Failure.provider("server_error")).canRetry)
        XCTAssertFalse(CloudFailure(CloudProtocol.Failure.provider("invalid_scope")).canRetry)
        XCTAssertFalse(CloudFailure(CloudProtocol.Failure.grant("Game stream", "invalid_client")).canRetry)
        XCTAssertTrue(CloudFailure(CloudProtocol.Failure.grant("Game stream", "access_denied")).canRetry)
        XCTAssertFalse(CloudFailure(CloudProtocol.Failure.websiteSessionRequired).canRetry, "Only a new sign-in helps")
        XCTAssertTrue(CloudFailure(CloudDatacenter.Failure.unreachable).canRetry)
        XCTAssertTrue(CloudFailure(URLError(.timedOut)).canRetry)
        XCTAssertNotEqual(CloudFailure(CloudProtocol.Failure.provider("server_error")).message, CloudFailure(CloudProtocol.Failure.provider("invalid_scope")).message)
    }

    func testARefusedAuthorizationSaysSonysReasonWhenThereIsOne() {
        func refusal(_ status: Int, _ body: String) -> CloudFailure {
            CloudFailure(CloudAuthorization.refusal(status: status, body: Data(body.utf8), named: "PS Cloud account", otherwise: "PS Cloud connection"))
        }
        let named = refusal(403, #"{"error":"access_denied","error_code":4165,"error_description":"user 123 is not allowed"}"#)
        XCTAssertTrue(named.message.contains("access_denied (4165)"), named.message)
        XCTAssertFalse(named.message.contains("123"), "The description can name the account and is never shown")
        XCTAssertTrue(named.canRetry)
        XCTAssertTrue(refusal(403, #"{"error":"unauthorized_client"}"#).message.contains("unauthorized_client"), "A name the app has not met is still a name")
        XCTAssertTrue(refusal(400, #"{"error_code":4428}"#).message.contains("4428"))
        XCTAssertFalse(refusal(400, #"{"error":"invalid_scope","error_code":4100}"#).canRetry, "The request itself is wrong: sending it again changes nothing")
        let text = refusal(403, #"{"error":"The account of John is blocked"}"#).message
        XCTAssertFalse(text.contains("John"))
        XCTAssertEqual(text, english("%@: Sony returned HTTP %@.", english("PS Cloud connection"), 403))
        let gateway = refusal(403, "<HTML><BODY>Access Denied</BODY></HTML>").message
        XCTAssertEqual(gateway, english("%@: Sony's network gateway rejected the request (HTTP 403).", english("PS Cloud connection")))
        XCTAssertEqual(refusal(500, "oops").message, english("%@: Sony returned HTTP %@.", english("PS Cloud connection"), 500))
    }

    func testSonysCodesAreSaidInWords() {
        func code(_ code: String) -> String { CloudFailure(CloudProtocol.Failure.serviceCode(403, "Game server allocation", code, "")).message }
        XCTAssertEqual(code("002.2001"), english("Sony requires a PlayStation Plus Premium subscription for this game."))
        XCTAssertTrue(code("002.2008").contains("002.2008"))
        XCTAssertTrue(code("002.0019").contains(String(CloudPingPolicy.limitMs)), "The message names the ping limit")
        let far = CloudFailure(CloudPingPolicy.TooFar(ms: 104))
        XCTAssertTrue(far.message.contains("104") && far.message.contains(String(CloudPingPolicy.limitMs)), far.message)
        XCTAssertFalse(far.canRetry, "Trying again does not bring the server closer")
        XCTAssertTrue(code("002.9999").contains("002.9999") && code("002.9999").contains("403"))
        let described = CloudFailure(CloudProtocol.Failure.serviceCode(401, "Preparing the game session", "002.0011", "Not authorized")).message
        XCTAssertTrue(described.contains("002.0011") && described.contains("Not authorized"), described)
        XCTAssertEqual(CloudSessionService.readable("Bad\nthing\u{7}  "), "Badthing")
        XCTAssertEqual(CloudFailure(CloudProtocol.Failure.serviceEvent(404, "Creating the cloud session", "noGameForEntitlementId")).message, english("Sony did not confirm a cloud license for this game."))
        XCTAssertTrue(CloudFailure(CloudProtocol.Failure.serviceEvent(403, "Creating the cloud session", "gatewayDenied")).message.contains("403"))
        XCTAssertEqual(CloudFailure(CloudProtocol.Failure.serviceEvent(500, "Creating the cloud session", "somethingNew")).message, english("%@: HTTP %@, Sony event %@.", english("Creating the cloud session"), 500, "somethingNew"))
        XCTAssertTrue(CloudFailure(CloudAllocation.Failure.queueTimeout(position: 7)).message.contains("7"))
        XCTAssertFalse(CloudFailure(CloudAllocation.Failure.queueTimeout(position: nil)).message.contains("("))
    }

    func testOnlyAPreviousSessionIsWaitedFor() {
        for waiting: Error in [CloudProtocol.Failure.sessionBusy, CloudProtocol.Failure.serviceCode(400, "Server request", "002.2008", "")] {
            XCTAssertTrue(CloudFailure(waiting).waitsForPreviousSession, "\(waiting)"); XCTAssertTrue(CloudFailure(waiting).canRetry)
        }
        for other: Error in [CloudProtocol.Failure.service(500, "Preparing the game session"), CloudProtocol.Failure.serviceCode(400, "Server request", "002.2001", ""), URLError(.timedOut), CloudDatacenter.Failure.unreachable] {
            XCTAssertFalse(CloudFailure(other).waitsForPreviousSession, "\(other)")
        }
    }

    func testASilentServerIsExplainedByHowItWasChosen() {
        let automatic = CloudFailure(CloudDatacenter.Failure.unreachable, automaticServer: true).message
        let chosen = CloudFailure(CloudDatacenter.Failure.unreachable, automaticServer: false).message
        XCTAssertNotEqual(automatic, chosen)
        XCTAssertTrue(automatic.contains("VPN"))
    }

    func testARefusedLicensePointsToTheSameGameOnAnotherTab() {
        let plain = CloudFailure(CloudEntitlementService.Failure.unavailable).message
        XCTAssertEqual(plain, CloudFailure.noLicense)
        let owned = CloudFailure(CloudEntitlementService.Failure.unavailable, elsewhere: ("PS4", true)).message
        let other = CloudFailure(CloudEntitlementService.Failure.unavailable, elsewhere: ("PS3", false)).message
        XCTAssertTrue(owned.hasPrefix(plain + " ") && owned.hasSuffix(english("Your version of this game is on the %@ tab.", "PS4")))
        XCTAssertTrue(other.hasSuffix(english("A game with this name is on the %@ tab.", "PS3")))
        XCTAssertFalse(CloudFailure(CloudProtocol.Failure.sessionBusy, elsewhere: ("PS4", true)).message.contains("PS4"), "Only a refused license sends the player elsewhere")
    }

    func testEveryFailureOfThePreparationHasWordsOfItsOwn() {
        let failures: [Error] = [PSPlusPCService.Failure.notFree, PSPlusPCService.Failure.activationFailed, PSPlusPCService.Failure.unavailable, PSPlusPCService.Failure.service(500),
                                 CloudDatacenter.Failure.emptyList, CloudDatacenter.Failure.invalidName, CloudDatacenter.Failure.invalidAddress, CloudDatacenter.Failure.invalidPort,
                                 CloudDatacenter.Failure.duplicate, CloudDatacenter.Failure.invalidSchema, CloudProtocol.Failure.sessionBusy, CloudProtocol.Failure.service(500, "Creating the cloud session"),
                                 CloudProtocol.Failure.invalidCallback, CloudProtocol.Failure.cancelled, CloudProtocol.Failure.invalidResponse, CloudEntitlementService.Failure.service(500),
                                 CloudEntitlementService.Failure.invalidResponse, CloudAllocation.Failure.invalidSlot]
        let general = CloudFailure(URLError(.timedOut)).message
        let messages = failures.map { CloudFailure($0).message }
        XCTAssertEqual(Set(messages).count, failures.count)
        XCTAssertFalse(messages.contains(general))
        for message in messages { XCTAssertFalse(message.unicodeScalars.contains { (0x400...0x4ff).contains($0.value) }, message) }
    }

    private func preparation(measured: Int?, reported: Int?) throws -> CloudAuthorization.Preparation {
        let centers = try CloudDatacenter.decode(Data(#"[{"dataCenter":"fraa","publicIp":"192.0.2.10","port":2053},{"dataCenter":"frab","publicIp":"192.0.2.11","port":2053}]"#.utf8))
        let slot = #"{"launchSlot":{"publicIp":"192.0.2.20","port":2054,"privateIp":"10.0.0.9"},"handshakeKey":"AAECAwQFBgcICQoLDA0ODw==","sessionId":"session-1","launchSpecification":"spec"}"#
        guard case .ready(let launch) = try CloudAllocation.decode(Data(slot.utf8)) else { throw CloudAllocation.Failure.invalidSlot }
        return .init(centers: centers, latencies: measured.map { ["fraa": $0] } ?? [:], selected: centers[0], reportedLatency: reported, mtuIn: 1400, mtuOut: 1200, slot: launch)
    }

    func testAPreparedServerBecomesTheStreamOfItsGame() throws {
        let game = Game(id: "pc:x", title: "Bloodborne", platform: "PS4", favorite: false, artworkURL: URL(string: "https://example.com/a.png"), productID: "X", cloudBackend: .psPlusPC)
        let stream = CloudStream(try preparation(measured: 104, reported: 75), game: game, height: 1440)
        XCTAssertEqual(stream.slot.host, "192.0.2.20"); XCTAssertEqual(stream.slot.port, 2054)
        XCTAssertEqual(stream.slot.packetPrefix, 9, "The last number of the private address")
        XCTAssertEqual(stream.slot.sessionID, "session-1"); XCTAssertEqual(stream.slot.handshakeKey.count, 16)
        XCTAssertEqual(stream.slot.mtuIn, 1400); XCTAssertEqual(stream.slot.mtuOut, 1200)
        XCTAssertEqual(stream.slot.rttMs, 104, "The engine paces by what was measured, not by what Sony was told")
        XCTAssertFalse(stream.slot.isPS5)
        XCTAssertEqual(stream.title, "Bloodborne · PS4")
        XCTAssertEqual(stream.resolution, 1080, "The PS4 cloud has nothing above 1080p")
        XCTAssertEqual(stream.game, StreamGame(title: "Bloodborne", platform: "PS4", artwork: URL(string: "https://example.com/a.png")))
        XCTAssertEqual(stream.measuredPingMs, 104); XCTAssertEqual(stream.reportedPingMs, 75)
        XCTAssertEqual(stream.server, localizedCity("Frankfurt, Germany · A"), "Two sites in one city get distinct names")
        XCTAssertEqual(stream.status, english("Server: %@%@.", stream.server, english(", %@ ms", 104) + english(" (%@ ms reported to Sony)", 75)))
    }

    func testAPS5StreamKeepsItsHeightAndSaysNothingOfAPingItDidNotSubstitute() throws {
        let game = Game(id: "concept:1", title: "Astro Bot", platform: "PS5", favorite: false, artworkURL: nil, conceptID: 1)
        let stream = CloudStream(try preparation(measured: 40, reported: 40), game: game, height: 2160)
        XCTAssertTrue(stream.slot.isPS5); XCTAssertEqual(stream.resolution, 2160); XCTAssertEqual(stream.title, "Astro Bot · PS5")
        XCTAssertEqual(stream.status, english("Server: %@%@.", stream.server, english(", %@ ms", 40)))
        let blind = CloudStream(try preparation(measured: nil, reported: nil), game: nil, height: 1080)
        XCTAssertEqual(blind.slot.rttMs, 25); XCTAssertNil(blind.game); XCTAssertEqual(blind.title, "PS Cloud")
        XCTAssertEqual(blind.status, english("Server: %@%@.", blind.server, ""))
    }
}
