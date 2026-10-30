import AVFoundation
import SwiftUI

public final class VideoSurfaceView: NSView {
    public let displayLayer = AVSampleBufferDisplayLayer()
    public let pacer = RefreshPacer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public var fillsView = false {
        didSet { displayLayer.videoGravity = fillsView ? .resizeAspectFill : .resizeAspect }
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pacer.attach(to: window == nil ? nil : self)
    }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        displayLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    public var onPointerActivity: (() -> Void)?
    public var onPointerDown: (() -> Void)?
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    public override func mouseMoved(with event: NSEvent) { onPointerActivity?(); super.mouseMoved(with: event) }
    public override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    public override func mouseDown(with event: NSEvent) { onPointerActivity?(); onPointerDown?(); super.mouseDown(with: event) }
}

public struct VideoSurface: NSViewRepresentable {
    private let view: VideoSurfaceView
    public init(view: VideoSurfaceView) { self.view = view }
    public func makeNSView(context: Context) -> VideoSurfaceView { view }
    public func updateNSView(_ nsView: VideoSurfaceView, context: Context) {}
}
