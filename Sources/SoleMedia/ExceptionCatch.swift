import CConPlatform
import Foundation

func SoleCatchException(_ body: @escaping () -> Void) -> NSException? {
    final class Body { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
    let held = Body(body)
    var raised: UnsafeMutableRawPointer?
    let didRaise = withExtendedLifetime(held) {
        con_objc_catch({ context in
            guard let context else { return }
            Unmanaged<Body>.fromOpaque(context).takeUnretainedValue().run()
        }, Unmanaged.passUnretained(held).toOpaque(), &raised)
    }
    guard didRaise else { return nil }
    guard let raised else { return NSException(name: .genericException, reason: "nil was raised", userInfo: nil) }
    let object = Unmanaged<AnyObject>.fromOpaque(raised).takeRetainedValue()
    return object as? NSException ?? NSException(name: .genericException, reason: String(describing: object), userInfo: nil)
}
