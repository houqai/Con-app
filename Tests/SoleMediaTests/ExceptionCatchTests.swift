import Foundation
import Testing
@testable import SoleMedia

@Suite struct ExceptionCatchTests {
    @Test func returnsWhatTheBlockRaised() {
        let caught = SoleCatchException {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"), reason: "player did not see an IO cycle.").raise()
        }
        #expect(caught?.reason == "player did not see an IO cycle.")
    }

    @Test func returnsNothingWhenTheBlockFinishes() {
        var ran = false
        #expect(SoleCatchException { ran = true } == nil)
        #expect(ran)
    }
}
