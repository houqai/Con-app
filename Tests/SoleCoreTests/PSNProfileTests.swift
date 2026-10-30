import XCTest
@testable import SoleCore

final class PSNProfileTests: XCTestCase {
    func testPicksLargestAvatarAndMembership() throws {
        let json = #"{"onlineId":"player","aboutMe":"","avatars":[{"size":"s","url":"https://psn-rsc.prod.dl.playstation.net/a_s.png"},{"size":"xl","url":"https://psn-rsc.prod.dl.playstation.net/a_xl.png"},{"size":"m","url":"https://psn-rsc.prod.dl.playstation.net/a_m.png"}],"isPlus":true}"#
        let profile = try XCTUnwrap(PSNProfile.decode(Data(json.utf8)))
        XCTAssertEqual(profile.onlineID, "player")
        XCTAssertEqual(profile.avatarURL?.absoluteString, "https://psn-rsc.prod.dl.playstation.net/a_xl.png")
        XCTAssertEqual(profile.isPlus, true)
    }

    func testUpgradesLegacySonyAvatarAndRejectsUnsafeAddresses() throws {
        let legacy = #"{"onlineId":"player","avatars":[{"size":"l","url":"http://static-resource.np.community.playstation.net/avatar/default/DefaultAvatar_l.png"}]}"#
        XCTAssertEqual(PSNProfile.decode(Data(legacy.utf8))?.avatarURL?.absoluteString, "https://static-resource.np.community.playstation.net/avatar/default/DefaultAvatar_l.png")
        for url in ["http://example.com/a.png", "file:///etc/passwd", "https://user:secret@image.api.playstation.com/a.png", "javascript:alert(1)", "not a url"] {
            let object: [String: Any] = ["onlineId": "player", "avatars": [["size": "l", "url": url]]]
            let profile = try XCTUnwrap(PSNProfile.decode(JSONSerialization.data(withJSONObject: object)))
            XCTAssertNil(profile.avatarURL, url)
            XCTAssertNil(profile.isPlus)
        }
    }

    func testProfileWithoutNameIsRejected() {
        XCTAssertNil(PSNProfile.decode(Data(#"{"avatars":[]}"#.utf8)))
        XCTAssertNil(PSNProfile.decode(Data(#"{"onlineId":""}"#.utf8)))
        XCTAssertNil(PSNProfile.decode(Data("[]".utf8)))
        XCTAssertEqual(PSNProfile.decode(Data(#"{"onlineId":"player"}"#.utf8)), PSNProfile(onlineID: "player", avatarURL: nil, isPlus: nil))
    }
}
