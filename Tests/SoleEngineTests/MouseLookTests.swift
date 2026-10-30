import Testing
@testable import SoleEngine

@Suite struct MouseLookTests {
    private let pointsPerFullPush: Float = 6.66
    private func length(_ stick: (x: Float, y: Float)) -> Float { (stick.x * stick.x + stick.y * stick.y).squareRoot() }
    private func speed(_ stick: (x: Float, y: Float)) -> Float { max(0, (length(stick) - MouseLook.deadZone) / (1 - MouseLook.deadZone)) }
    private func turn(points: Float, over samples: Int, sensitivity: Float = 5) -> (total: Float, samplesMoving: Int) {
        var look = MouseLook(sensitivity: sensitivity)
        var total: Float = 0, moving = 0
        for sample in 0..<(samples + 400) {
            let stick = look.stick(dx: sample < samples ? points / Float(samples) : 0, dy: 0)
            total += speed(stick)
            if length(stick) > 0 { moving = sample + 1 }
        }
        return (total, moving)
    }

    @Test func aStillMouseLeavesTheStickAlone() {
        var look = MouseLook()
        for _ in 0..<5 { #expect(look.stick(dx: 0, dy: 0) == (0, 0)) }
    }
    @Test func theStickFollowsTheDirectionOfTheMouse() {
        var look = MouseLook()
        var stick = look.stick(dx: 4, dy: 0)
        #expect(stick.x > 0 && stick.y == 0)
        look = MouseLook(); stick = look.stick(dx: 0, dy: 4)
        #expect(stick.x == 0 && stick.y < 0, "the mouse going down looks down")
        look = MouseLook(); stick = look.stick(dx: -3, dy: -3)
        #expect(stick.x < 0 && stick.y > 0 && abs(stick.x + stick.y) < 0.001)
    }
    @Test func everyPushGetsPastTheDeadZoneOfAGame() {
        var look = MouseLook()
        for _ in 0..<200 {
            let stick = look.stick(dx: 0.2, dy: 0)
            #expect(length(stick) == 0 || length(stick) > MouseLook.deadZone)
        }
    }
    @Test func aSteadyMouseTurnsAtASpeedInProportionToItsOwn() {
        var slow = MouseLook(), twice = MouseLook()
        var slowStick = (x: Float(0), y: Float(0)), twiceStick = slowStick
        for _ in 0..<40 { slowStick = slow.stick(dx: 1, dy: 0); twiceStick = twice.stick(dx: 2, dy: 0) }
        #expect(abs(speed(slowStick) - 0.15) < 0.005)
        #expect(abs(speed(twiceStick) - 2 * speed(slowStick)) < 0.01)
    }
    @Test func theCameraTurnsAsFarForAJerkAsForASlowSweep() {
        let jerk = turn(points: 150, over: 2), sweep = turn(points: 150, over: 100)
        #expect(abs(jerk.total - sweep.total) / sweep.total < 0.05, "jerk \(jerk.total), sweep \(sweep.total)")
        #expect(abs(sweep.total - 150 / pointsPerFullPush) < 1)
        let longer = turn(points: 300, over: 100)
        #expect(abs(longer.total - 2 * sweep.total) / sweep.total < 0.05)
    }
    @Test func verySlowMovementIsNotLost() {
        let crawl = turn(points: 30, over: 300)
        #expect(abs(crawl.total - 30 / pointsPerFullPush) / (30 / pointsPerFullPush) < 0.1, "\(crawl.total)")
    }
    @Test func whatAJerkCanStillTurnHasALimit() {
        let jerk = turn(points: 100_000, over: 3)
        #expect(jerk.samplesMoving <= 60, "the camera stops within half a second: \(jerk.samplesMoving)")
        #expect(jerk.total > 40)
    }
    @Test func theStickReturnsWhenTheMouseStops() {
        let sweep = turn(points: 60, over: 60)
        #expect(sweep.samplesMoving - 60 <= 6, "no more than about 50 ms after a slow sweep: \(sweep.samplesMoving - 60)")
    }
    @Test func reversingTheMouseTakesBackWhatIsStillOwed() {
        var look = MouseLook()
        _ = look.stick(dx: 200, dy: 0)
        let stick = look.stick(dx: -200, dy: 0)
        #expect(stick.x <= 0.001, "the camera does not keep turning the old way: \(stick.x)")
    }
    @Test func sensitivityScalesTheTurnAndStaysInRange() {
        let slow = turn(points: 100, over: 50, sensitivity: 2), fast = turn(points: 100, over: 50, sensitivity: 8)
        #expect(abs(fast.total / slow.total - 4) < 0.3)
        #expect(MouseLook(sensitivity: 50).sensitivity == 10 && MouseLook(sensitivity: -1).sensitivity == 1)
    }
}
