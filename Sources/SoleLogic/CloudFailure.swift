import Foundation
import SoleCloud
import SoleCore
import SoleEngine

public struct CloudFailure: Equatable, Sendable {
    public let message: String
    public let canRetry: Bool
    public let waitsForPreviousSession: Bool

    public static var noLicense: String {
        loc("Con found no valid PS5 license that matches this game. That does not prove the game is missing from your library: the edition or the license data may differ from the catalog.")
    }

    public init(_ error: Error, automaticServer: Bool = true, elsewhere: (console: String, owned: Bool)? = nil) {
        func permanent(_ code: String) -> Bool { ["invalid_scope", "invalid_client", "invalid_request"].contains(String(code.prefix { $0 != " " })) }
        var retry = true, waits = false
        let text: String
        switch error {
        case PSPlusPCService.Failure.notFree: text = loc("Sony did not confirm free subscription access to this game. No purchase was made.")
        case PSPlusPCService.Failure.activationFailed: text = loc("Sony could not activate the PS Plus PC streaming license. Try launching again.")
        case PSPlusPCService.Failure.unavailable: text = loc("Sony did not confirm access to the streaming version of this game.")
        case PSPlusPCService.Failure.service(let status): text = loc("PS Plus PC: Sony returned HTTP %@.", status)
        case CloudProtocol.Failure.grant(let stage, let code):
            retry = !permanent(code)
            text = loc("%@: Sony returned %@.", loc(stage), code)
        case CloudProtocol.Failure.provider(let code):
            retry = !permanent(code)
            if retry {
                text = loc("Sony rejected the cloud connection (%@).", code)
            } else {
                text = loc("Sony rejected the PS Cloud configuration (%@). The cloud connection needs more work.", code)
            }
        case CloudProtocol.Failure.websiteSessionRequired:
            retry = false
            text = loc("The cloud needs your saved sign-in refreshed. Open PSN Account and choose Refresh sign-in.")
        case let far as CloudPingPolicy.TooFar:
            retry = false
            text = loc("The server is %@ ms away, and Sony accepts up to %@ ms. To play anyway, turn on Distant servers in the stream settings.", far.ms, CloudPingPolicy.limitMs)
        case CloudDatacenter.Failure.probeTimeout:
            text = loc("Sony network checks did not finish in time. This does not mean UDP is blocked. Try connecting again.")
        case CloudDatacenter.Failure.unreachable:
            if automaticServer {
                text = loc("Sony's servers did not answer the UDP network check, so no server was chosen. Check that a VPN or firewall is not blocking outgoing UDP.")
            } else {
                text = loc("The chosen server did not answer the UDP network check. Choose Automatic in the stream settings or try again later.")
            }
        case CloudDatacenter.Failure.emptyList: text = loc("Sony has not offered servers for this game yet. Try another game or try again later.")
        case CloudDatacenter.Failure.invalidName: text = loc("Sony returned an unknown datacenter identifier.")
        case CloudDatacenter.Failure.invalidAddress: text = loc("Sony returned an unsupported datacenter address.")
        case CloudDatacenter.Failure.invalidPort: text = loc("Sony returned an invalid datacenter port.")
        case CloudDatacenter.Failure.duplicate: text = loc("Sony returned duplicate datacenters.")
        case CloudDatacenter.Failure.invalidSchema: text = loc("The format of Sony's datacenter list needs more work.")
        case CloudProtocol.Failure.serviceCode(let http, let stage, let code, let description):
            waits = code == "002.2008"
            switch code {
            case "002.2001":
                text = loc("Sony requires a PlayStation Plus Premium subscription for this game.")
            case "002.2008":
                text = loc("Sony is still preparing the server after the last session (code 002.2008). Try again in a minute.")
            case "002.0019":
                text = loc("%@: Sony rejected the latency to the server (HTTP %@, code 002.0019) although no more than %@ ms was reported.", loc(stage), http, CloudPingPolicy.limitMs)
            case "002.2005":
                text = loc("%@: Sony did not accept the session key (HTTP %@, code 002.2005). Prepare the stream again.", loc(stage), http)
            default:
                text = description.isEmpty ? loc("%@: HTTP %@, Sony code %@.", loc(stage), http, code)
                    : loc("%@: HTTP %@, Sony code %@: %@.", loc(stage), http, code, description)
            }
        case CloudProtocol.Failure.sessionBusy:
            waits = true
            text = loc("The account still has a cloud session — on this or another device. Con waited about a minute and a half for it to end. Start again when it is over.")
        case CloudProtocol.Failure.serviceEvent(_, let stage, "gatewayDenied"):
            text = loc("%@: Sony's network gateway rejected the request (HTTP 403).", loc(stage))
        case CloudProtocol.Failure.serviceEvent(let code, let stage, let event):
            if ["noGameForEntitlementId", "noGameForEntitlement"].contains(event) {
                text = loc("Sony did not confirm a cloud license for this game.")
            } else {
                text = loc("%@: HTTP %@, Sony event %@.", loc(stage), code, event)
            }
        case CloudProtocol.Failure.service(let code, let stage): text = loc("%@: Sony returned HTTP %@.", loc(stage), code)
        case CloudProtocol.Failure.invalidCallback: text = loc("Sony did not confirm the cloud sign-in. Connect again.")
        case CloudProtocol.Failure.cancelled: text = loc("Cloud sign-in cancelled.")
        case CloudProtocol.Failure.invalidResponse: text = loc("The answer from Sony's cloud service is not what was expected. The connection was not completed.")
        case CloudAllocation.Failure.queueTimeout(let position):
            text = loc("Sony did not assign a server in time") + (position.map { loc(" (queue position %@)", $0) } ?? "") + loc(". Try again later.")
        case CloudEntitlementService.Failure.unavailable:
            if let elsewhere {
                let hint = elsewhere.owned
                    ? loc("Your version of this game is on the %@ tab.", elsewhere.console)
                    : loc("A game with this name is on the %@ tab.", elsewhere.console)
                text = Self.noLicense + " " + hint
            } else {
                text = Self.noLicense
            }
        case CloudEntitlementService.Failure.service(let code): text = loc("Game license check: Sony returned HTTP %@.", code)
        case CloudEntitlementService.Failure.invalidResponse: text = loc("Sony returned game licenses in an unknown format.")
        case CloudAllocation.Failure.invalidSlot: text = loc("Sony's answer about the assigned server is not what was expected. The format needs more work.")
        default: text = loc("Could not connect to PS Cloud. Try again.")
        }
        message = text; canRetry = retry; waitsForPreviousSession = waits
    }
}
