import XCTest
import SoleCloud
import SoleCore
@testable import SoleLogic

final class PSNAuthorizationTests: XCTestCase {
    private actor MemoryStore: CredentialStore {
        var records: [String: Data] = [:]
        var broken = false
        var reads: [String] = []
        func read(_ account: String) async throws -> Data? {
            reads.append(account)
            if broken { throw CredentialStoreFailure("The vault is shut.") }
            return records[account]
        }
        func write(_ data: Data, account: String) async throws { records[account] = data }
        func remove(_ account: String) async throws {
            if broken { throw CredentialStoreFailure("The vault is shut.") }
            records[account] = nil
        }
        func put(_ data: Data, _ account: String) { records[account] = data }
        func shut() { broken = true }
    }
    @MainActor private final class Page: SonyLoginPage {
        var asked: (url: URL, state: String)?
        var cancelled = 0
        func signIn(url: URL, state: String) async throws -> SonyLogin {
            asked = (url, state)
            throw PSNAuthorization.AuthError.cancelled
        }
        func cancel() { cancelled += 1 }
    }
    private func sso(_ value: String, expiresIn: TimeInterval) -> Data {
        Data(#"{"value":"\#(value)","expiresAt":\#(Date().timeIntervalSinceReferenceDate + expiresIn)}"#.utf8)
    }

    @MainActor func testTheWebsiteSessionComesFromTheStoreAndAnExpiredOneAsksForANewSignIn() async throws {
        let store = MemoryStore()
        let session = PSNAuthorization(store: store, website: Page())
        do { _ = try await session.cloudSSO(); XCTFail("Nothing is stored") } catch CloudProtocol.Failure.websiteSessionRequired {}
        await store.put(sso("abcDEF123", expiresIn: 3600), PSNAuthorization.ssoAccount)
        let value = try await session.cloudSSO()
        XCTAssertEqual(value, "abcDEF123")
        let reads = await store.reads.count
        _ = try await session.cloudSSO()
        let after = await store.reads.count
        XCTAssertEqual(after, reads, "A valid session is kept in memory")

        let stale = MemoryStore()
        await stale.put(sso("old", expiresIn: -60), PSNAuthorization.ssoAccount)
        do { _ = try await PSNAuthorization(store: stale, website: Page()).cloudSSO(); XCTFail("It has expired") } catch CloudProtocol.Failure.websiteSessionRequired {}
    }

    @MainActor func testWithoutAStoredSignInNothingIsRestoredAndNothingIsAskedOfSony() async throws {
        let store = MemoryStore()
        let session = PSNAuthorization(store: store, website: Page())
        let profile = try await session.restore()
        XCTAssertNil(profile)
        let reads = await store.reads
        XCTAssertEqual(reads, [PSNAuthorization.refreshAccount])
    }

    @MainActor func testAStoreThatRefusesSaysSoInItsOwnWords() async {
        let store = MemoryStore()
        await store.shut()
        let session = PSNAuthorization(store: store, website: Page())
        do { _ = try await session.restore(); XCTFail("The store is shut") }
        catch { XCTAssertEqual((error as? PSNAuthorization.AuthError)?.errorDescription, "The vault is shut.") }
        do { _ = try await session.cloudSSO(); XCTFail("The store is shut") }
        catch { XCTAssertEqual((error as? PSNAuthorization.AuthError)?.errorDescription, "The vault is shut.") }
        do { try await session.signOut(); XCTFail("The store is shut") }
        catch { XCTAssertEqual((error as? PSNAuthorization.AuthError)?.errorDescription, "The vault is shut.") }
    }

    @MainActor func testSigningOutRemovesBothRecordsAndClosesThePage() async throws {
        let store = MemoryStore(), page = Page()
        await store.put(Data("token".utf8), PSNAuthorization.refreshAccount)
        await store.put(sso("abc", expiresIn: 3600), PSNAuthorization.ssoAccount)
        let session = PSNAuthorization(store: store, website: page)
        _ = try await session.cloudSSO()
        try await session.signOut()
        let left = await store.records
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(page.cancelled, 1)
        do { _ = try await session.cloudSSO(); XCTFail("Signed out") } catch CloudProtocol.Failure.websiteSessionRequired {}
    }

    @MainActor func testThePageIsAskedForSonysOwnAddressWithTheStateOfTheRequest() async {
        let page = Page()
        let session = PSNAuthorization(store: MemoryStore(), website: page)
        do { _ = try await session.signIn(); XCTFail("The page was closed") } catch {}
        let asked = page.asked
        XCTAssertEqual(asked?.url.host, "ca.account.sony.com"); XCTAssertEqual(asked?.url.scheme, "https")
        let query = URLComponents(url: asked!.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "state" }?.value, asked?.state)
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, PSNCallback.redirect)
        XCTAssertEqual(query.first { $0.name == "response_type" }?.value, "code")
        XCTAssertGreaterThanOrEqual(asked?.state.count ?? 0, 64, "A state nobody can guess")
        let again = PSNAuthorization.signInURL(state: "s")
        XCTAssertNotEqual(again, asked?.url)
    }

    @MainActor func testARefusalNamesOnlyKnownReasons() async {
        func reason(_ body: String) -> String? {
            if case .service(_, _, let reason) = PSNAuthorization.serviceError(400, step: "Step", data: Data(body.utf8)) { return reason }
            return "?"
        }
        XCTAssertEqual(reason(#"{"error":"invalid_grant","error_description":"user 123 private"}"#), "invalid_grant")
        XCTAssertNil(reason(#"{"error":"something private about the account"}"#))
        XCTAssertEqual(reason(#"{"error":{"code":2281604,"message":"private"}}"#), "2281604")
        XCTAssertNil(reason("not json"))
        let text = PSNAuthorization.AuthError.service(400, "Step", "invalid_grant").errorDescription ?? ""
        XCTAssertTrue(text.contains("Step") && text.contains("400") && text.contains("(invalid_grant)"))
        XCTAssertEqual(PSNAuthorization.AuthError.storage("In its words").errorDescription, "In its words")
    }
}
