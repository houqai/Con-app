import CCairo
import CConDesktop
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoleCore

struct Colour: Equatable {
    var r, g, b, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(bytes r: Int, _ g: Int, _ b: Int, _ a: Double = 1) { self.init(Double(r) / 255, Double(g) / 255, Double(b) / 255, a) }
    func with(_ alpha: Double) -> Colour { Colour(r, g, b, alpha) }

    static let canvas = Colour(bytes: 7, 10, 20)
    static let accent = Colour(0.56, 0.71, 1)
    static let text = Colour(bytes: 244, 246, 251)
    static let panel = Colour(bytes: 18, 21, 34)
    static let danger = Colour(bytes: 255, 138, 128)
    static let red = Colour(bytes: 219, 64, 69)
    static let white = Colour(1, 1, 1)
    static let black = Colour(0, 0, 0)
    static let scrim = Colour(bytes: 3, 5, 12, 0.55)
    static func white(_ alpha: Double) -> Colour { Colour(1, 1, 1, alpha) }
    static func black(_ alpha: Double) -> Colour { Colour(0, 0, 0, alpha) }
    static func hue(_ hue: Double, lightness: Double = 0.42, chroma: Double = 0.11) -> Colour {
        let rgb = ColorWheel.rgb(hue: hue, lightness: lightness, chroma: chroma)
        return Colour(rgb.red, rgb.green, rgb.blue)
    }
}

struct Box: Equatable {
    var x, y, w, h: Double
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var mid: (x: Double, y: Double) { (x + w / 2, y + h / 2) }
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
    func inset(_ d: Double) -> Box { Box(x: x + d, y: y + d, w: w - 2 * d, h: h - 2 * d) }
    func intersects(_ other: Box) -> Bool { x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY }
}

final class Canvas {
    let cairo: OpaquePointer
    init(cairo: OpaquePointer, scale: Double) {
        self.cairo = cairo
        cairo_scale(cairo, scale, scale)
    }

    func set(_ colour: Colour) { cairo_set_source_rgba(cairo, colour.r, colour.g, colour.b, colour.a) }

    func rounded(_ box: Box, _ radius: Double) {
        let r = min(radius, box.w / 2, box.h / 2)
        cairo_new_sub_path(cairo)
        cairo_arc(cairo, box.maxX - r, box.y + r, r, -.pi / 2, 0)
        cairo_arc(cairo, box.maxX - r, box.maxY - r, r, 0, .pi / 2)
        cairo_arc(cairo, box.x + r, box.maxY - r, r, .pi / 2, .pi)
        cairo_arc(cairo, box.x + r, box.y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(cairo)
    }
    func fill(_ box: Box, _ colour: Colour, radius: Double = 0) {
        set(colour); rounded(box, radius); cairo_fill(cairo)
    }
    func stroke(_ box: Box, _ colour: Colour, radius: Double = 0, width: Double = 1) {
        set(colour); cairo_set_line_width(cairo, width); rounded(box.inset(width / 2), max(0, radius - width / 2)); cairo_stroke(cairo)
    }
    func capsule(_ box: Box, _ colour: Colour) { fill(box, colour, radius: box.h / 2) }
    func shadow(_ box: Box, radius: Double, blur: Double, dy: Double, opacity: Double) {
        let steps = 8
        for step in 0..<steps {
            let spread = blur * Double(step + 1) / Double(steps)
            let alpha = opacity * (1 - Double(step) / Double(steps)) / Double(steps) * 2
            fill(Box(x: box.x - spread / 2, y: box.y - spread / 2 + dy, w: box.w + spread, h: box.h + spread), .black(alpha), radius: radius + spread / 2)
        }
    }
    func ring(_ box: Box, radius: Double, outset: Double, width: Double, _ colour: Colour) {
        stroke(box.inset(-(outset + width / 2)), colour, radius: radius + outset + width / 2, width: width)
    }
    func circle(_ x: Double, _ y: Double, _ r: Double, _ colour: Colour, stroke: Double = 0) {
        set(colour); cairo_new_sub_path(cairo); cairo_arc(cairo, x, y, r, 0, 2 * .pi)
        if stroke > 0 { cairo_set_line_width(cairo, stroke); cairo_stroke(cairo) } else { cairo_fill(cairo) }
    }
    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ colour: Colour, width: Double) {
        set(colour); cairo_set_line_width(cairo, width); cairo_set_line_cap(cairo, CAIRO_LINE_CAP_ROUND)
        cairo_move_to(cairo, x1, y1); cairo_line_to(cairo, x2, y2); cairo_stroke(cairo)
    }

    func save() { cairo_save(cairo) }
    func restore() { cairo_restore(cairo) }
    func clip(_ box: Box, radius: Double = 0) { rounded(box, radius); cairo_clip(cairo) }

    func gradient(_ box: Box, from top: Colour, to bottom: Colour, radius: Double = 0) {
        let pattern = cairo_pattern_create_linear(box.x, box.y, box.x, box.maxY)
        cairo_pattern_add_color_stop_rgba(pattern, 0, top.r, top.g, top.b, top.a)
        cairo_pattern_add_color_stop_rgba(pattern, 1, bottom.r, bottom.g, bottom.b, bottom.a)
        cairo_set_source(cairo, pattern); rounded(box, radius); cairo_fill(cairo)
        cairo_pattern_destroy(pattern)
    }
    func glow(_ x: Double, _ y: Double, _ radius: Double, _ colour: Colour, over box: Box) {
        let pattern = cairo_pattern_create_radial(x, y, 0, x, y, radius)
        cairo_pattern_add_color_stop_rgba(pattern, 0, colour.r, colour.g, colour.b, colour.a)
        cairo_pattern_add_color_stop_rgba(pattern, 1, colour.r, colour.g, colour.b, 0)
        cairo_set_source(cairo, pattern); cairo_rectangle(cairo, box.x, box.y, box.w, box.h); cairo_fill(cairo)
        cairo_pattern_destroy(pattern)
    }

    enum Weight { case regular, medium, semibold, bold }
    private static let fontOptions: OpaquePointer = {
        let options = cairo_font_options_create()!
        cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY)
        cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_NONE)
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF)
        return options
    }()
    private func layout(_ text: String, size: Double, weight: Weight, width: Double?, lines: Int) -> OpaquePointer {
        let layout = pango_cairo_create_layout(cairo)!
        let context = pango_layout_get_context(layout)
        pango_cairo_context_set_font_options(context, Self.fontOptions)
        pango_context_set_round_glyph_positions(context, 0)
        pango_layout_context_changed(layout)
        let font = pango_font_description_new()!
        pango_font_description_set_family(font, "Inter, Cantarell, Noto Sans, Sans")
        pango_font_description_set_absolute_size(font, size * Double(PANGO_SCALE))
        let pangoWeight: PangoWeight
        switch weight {
        case .regular: pangoWeight = PANGO_WEIGHT_NORMAL
        case .medium: pangoWeight = PANGO_WEIGHT_MEDIUM
        case .semibold: pangoWeight = PANGO_WEIGHT_SEMIBOLD
        case .bold: pangoWeight = PANGO_WEIGHT_BOLD
        }
        pango_font_description_set_weight(font, pangoWeight)
        pango_layout_set_font_description(layout, font)
        pango_font_description_free(font)
        pango_layout_set_text(layout, text, -1)
        if let width {
            pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
            pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            pango_layout_set_height(layout, lines > 0 ? -Int32(lines) : -1)
        }
        return layout
    }
    func measure(_ text: String, size: Double, weight: Weight = .regular, width: Double? = nil, lines: Int = 1) -> (w: Double, h: Double) {
        let made = layout(text, size: size, weight: weight, width: width, lines: lines)
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_size(made, &w, &h)
        g_object_unref(UnsafeMutableRawPointer(made))
        return (Double(w) / Double(PANGO_SCALE), Double(h) / Double(PANGO_SCALE))
    }
    @discardableResult
    func text(_ text: String, x: Double, y: Double, size: Double, weight: Weight = .regular, colour: Colour = .text,
              width: Double? = nil, lines: Int = 1, centred: Bool = false) -> (w: Double, h: Double) {
        let made = layout(text, size: size, weight: weight, width: width, lines: lines)
        if centred { pango_layout_set_alignment(made, PANGO_ALIGN_CENTER) }
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_size(made, &w, &h)
        set(colour)
        cairo_move_to(cairo, x, y)
        pango_cairo_show_layout(cairo, made)
        g_object_unref(UnsafeMutableRawPointer(made))
        return (Double(w) / Double(PANGO_SCALE), Double(h) / Double(PANGO_SCALE))
    }
    @discardableResult
    func label(_ text: String, x: Double, midY: Double, size: Double, weight: Weight = .regular, colour: Colour = .text, maxWidth: Double? = nil) -> Double {
        let measured = measure(text, size: size, weight: weight, width: maxWidth)
        self.text(text, x: x, y: midY - measured.h / 2, size: size, weight: weight, colour: colour, width: maxWidth)
        return measured.w
    }
    func centred(_ text: String, in box: Box, size: Double, weight: Weight = .regular, colour: Colour = .text) {
        let made = measure(text, size: size, weight: weight)
        self.text(text, x: box.mid.x - made.w / 2, y: box.mid.y - made.h / 2, size: size, weight: weight, colour: colour)
    }

    func picture(_ surface: OpaquePointer, cover box: Box, radius: Double = 0, alpha: Double = 1) {
        let w = Double(cairo_image_surface_get_width(surface)), h = Double(cairo_image_surface_get_height(surface))
        guard w > 0, h > 0 else { return }
        save()
        clip(box, radius: radius)
        let factor = max(box.w / w, box.h / h)
        cairo_translate(cairo, box.mid.x - w * factor / 2, box.mid.y - h * factor / 2)
        cairo_scale(cairo, factor, factor)
        cairo_set_source_surface(cairo, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cairo), factor > 4 ? CAIRO_FILTER_BILINEAR : CAIRO_FILTER_GOOD)
        if factor > 4 { cairo_pattern_set_extend(cairo_get_source(cairo), CAIRO_EXTEND_PAD) }
        cairo_paint_with_alpha(cairo, alpha)
        restore()
    }

    func icon(_ name: String, in box: Box, colour: Colour, weight: Double = 2) {
        save()
        let factor = min(box.w, box.h) / 24
        cairo_translate(cairo, box.mid.x - 12 * factor, box.mid.y - 12 * factor)
        cairo_scale(cairo, factor, factor)
        set(colour)
        cairo_set_line_width(cairo, weight)
        cairo_set_line_cap(cairo, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cairo, CAIRO_LINE_JOIN_ROUND)
        let c = cairo
        func move(_ x: Double, _ y: Double) { cairo_move_to(c, x, y) }
        func to(_ x: Double, _ y: Double) { cairo_line_to(c, x, y) }
        switch name {
        case "reload":
            cairo_new_sub_path(c); cairo_arc(c, 12, 12, 8, -.pi / 3, 1.5 * .pi); cairo_stroke(c); move(16.5, 2.5); to(16.5, 6.8); to(12.2, 6.8); cairo_stroke(c)
        case "gear":
            cairo_new_sub_path(c); cairo_arc(c, 12, 12, 3.2, 0, 2 * .pi); cairo_stroke(c)
            cairo_new_sub_path(c); cairo_arc(c, 12, 12, 7, 0, 2 * .pi); cairo_stroke(c)
            for tooth in 0..<8 { let a = Double(tooth) * .pi / 4; move(12 + 7 * cos(a), 12 + 7 * sin(a)); to(12 + 10 * cos(a), 12 + 10 * sin(a)) }
            cairo_stroke(c)
        case "menu":
            for line in 0..<3 { move(4, 6 + Double(line) * 6); to(20, 6 + Double(line) * 6) }; cairo_stroke(c)
        case "star", "star.fill":
            for point in 0..<10 {
                let a = -.pi / 2 + Double(point) * .pi / 5, r = point % 2 == 0 ? 10.0 : 4.2
                point == 0 ? move(12 + r * cos(a), 12.8 + r * sin(a)) : to(12 + r * cos(a), 12.8 + r * sin(a))
            }
            cairo_close_path(c); cairo_set_line_width(c, 1.6)
            if name == "star.fill" { cairo_fill_preserve(c) }
            cairo_stroke(c)
        case "play":
            move(7, 4); to(20, 12); to(7, 20); cairo_close_path(c); cairo_fill(c)
        case "arrow.up.right":
            move(6, 18); to(18, 6); move(9, 6); to(18, 6); to(18, 15); cairo_stroke(c)
        case "chevron.left":
            move(15, 5); to(8, 12); to(15, 19); cairo_stroke(c)
        case "chevron.down":
            move(6, 9); to(12, 15); to(18, 9); cairo_stroke(c)
        case "xmark":
            move(6, 6); to(18, 18); move(18, 6); to(6, 18); cairo_stroke(c)
        case "search", "magnifier", "magnifier.plus":
            if name != "search" { cairo_set_line_width(c, 1.8) }
            cairo_new_sub_path(c); cairo_arc(c, 10, 10, 6.5, 0, 2 * .pi); cairo_stroke(c)
            move(15, 15); to(20.5, 20.5); cairo_stroke(c)
            if name == "magnifier.plus" { move(7, 10); to(13, 10); move(10, 7); to(10, 13); cairo_stroke(c) }
            else if name == "magnifier" { move(7.5, 12.5); to(12.5, 7.5); move(9.5, 7.5); to(12.5, 7.5); to(12.5, 10.5); cairo_stroke(c) }
        case "generation":
            cairo_set_line_width(c, 1.8)
            rounded(Box(x: 9, y: 4, w: 11, h: 11), 2.5); cairo_stroke(c)
            cairo_set_dash(c, [1.6, 2.2], 2, 0)
            rounded(Box(x: 4, y: 9, w: 11, h: 11), 2.5); cairo_stroke(c)
            cairo_set_dash(c, nil, 0, 0)
        case "chart":
            for (x, top) in [(4.0, 12.0), (10, 7), (16, 3)] { rounded(Box(x: x, y: top, w: 4, h: 20 - top), 1) }; cairo_fill(c)
        case "gamecontroller":
            cairo_set_line_width(c, 1.8)
            move(7, 7); to(17, 7); cairo_curve_to(c, 21, 7, 23, 13, 22.5, 17); cairo_curve_to(c, 22, 20, 19, 20.5, 17.5, 18.5)
            to(15.5, 16); to(8.5, 16); to(6.5, 18.5); cairo_curve_to(c, 5, 20.5, 2, 20, 1.5, 17); cairo_curve_to(c, 1, 13, 3, 7, 7, 7); cairo_close_path(c)
            cairo_stroke(c); move(5.5, 11.5); to(9.5, 11.5); move(7.5, 9.5); to(7.5, 13.5); cairo_stroke(c)
            cairo_arc(c, 16, 10.5, 1.1, 0, 2 * .pi); cairo_fill(c); cairo_arc(c, 18.2, 12.8, 1.1, 0, 2 * .pi); cairo_fill(c)
        case "keyboard":
            cairo_set_line_width(c, 1.7)
            let r = 2.5
            cairo_new_sub_path(c)
            cairo_arc(c, 21.5 - r, 6 + r, r, -.pi / 2, 0); cairo_arc(c, 21.5 - r, 18 - r, r, 0, .pi / 2)
            cairo_arc(c, 2.5 + r, 18 - r, r, .pi / 2, .pi); cairo_arc(c, 2.5 + r, 6 + r, r, .pi, 1.5 * .pi)
            cairo_close_path(c); cairo_stroke(c)
            for row in 0..<2 { for key in 0..<5 { cairo_arc(c, 6 + Double(key) * 3, 9.5 + Double(row) * 2.8, 0.85, 0, 2 * .pi); cairo_fill(c) } }
            move(8, 15); to(16, 15); cairo_stroke(c)
        case "computermouse":
            cairo_set_line_width(c, 1.7)
            cairo_new_sub_path(c)
            cairo_arc(c, 12, 8.5, 5.5, .pi, 2 * .pi); cairo_arc(c, 12, 15.5, 5.5, 0, .pi)
            cairo_close_path(c); cairo_stroke(c)
            move(12, 3.5); to(12, 8.5); cairo_stroke(c)
        case "person":
            cairo_set_line_width(c, 1.4)
            cairo_new_sub_path(c); cairo_arc(c, 12, 12, 10, 0, 2 * .pi); cairo_stroke(c)
            cairo_new_sub_path(c); cairo_arc(c, 12, 9.5, 3.5, 0, 2 * .pi); cairo_stroke(c)
            cairo_new_sub_path(c); cairo_arc(c, 12, 20, 6.5, 1.15 * .pi, 1.85 * .pi); cairo_stroke(c)
        case "waves":
            cairo_new_sub_path(c); cairo_arc(c, 12, 12, 1.5, 0, 2 * .pi); cairo_stroke(c)
            for r in [5.0, 9.0] {
                cairo_new_sub_path(c); cairo_arc(c, 12, 12, r, -.pi / 4, .pi / 4); cairo_stroke(c)
                cairo_new_sub_path(c); cairo_arc(c, 12, 12, r, 3 * .pi / 4, 5 * .pi / 4); cairo_stroke(c)
            }
        case "film":
            rounded(Box(x: 3, y: 4, w: 18, h: 16), 2.5); cairo_stroke(c)
            move(7.5, 4); to(7.5, 20); move(16.5, 4); to(16.5, 20); move(3, 12); to(7.5, 12); move(16.5, 12); to(21, 12); cairo_stroke(c)
        case "wifi":
            for r in [4.5, 9.0, 13.5] { cairo_new_sub_path(c); cairo_arc(c, 12, 20, r, -0.75 * .pi, -0.25 * .pi); cairo_stroke(c) }
            cairo_arc(c, 12, 20, 1.7, 0, 2 * .pi); cairo_fill(c)
        case "arrow.down":
            move(12, 4); to(12, 20); move(6, 14); to(12, 20); to(18, 14); cairo_stroke(c)
        case "tv":
            rounded(Box(x: 2, y: 4, w: 20, h: 14), 2.5); cairo_stroke(c); move(8, 21); to(16, 21); cairo_stroke(c)
        case "trophy":
            move(7, 4); to(17, 4); to(17, 9); cairo_curve_to(c, 17, 12.5, 14.8, 15, 12, 15); cairo_curve_to(c, 9.2, 15, 7, 12.5, 7, 9); cairo_close_path(c)
            move(17, 6); cairo_curve_to(c, 21, 6, 21, 11, 16.5, 11.5); move(7, 6); cairo_curve_to(c, 3, 6, 3, 11, 7.5, 11.5)
            move(12, 15); to(12, 19); move(8, 20); to(16, 20); cairo_stroke(c)
        case "fullscreen":
            move(4, 9); to(4, 4); to(9, 4); move(15, 4); to(20, 4); to(20, 9); move(20, 15); to(20, 20); to(15, 20); move(9, 20); to(4, 20); to(4, 15); cairo_stroke(c)
        default: break
        }
        restore()
    }
}

@MainActor final class Pictures {
    static let shared = Pictures()
    private static let session = URLSession.lasting(.default)
    private var kept: [String: OpaquePointer] = [:]
    private var order: [String] = []
    private var loading: Set<String> = []
    private var failedUntil: [String: Double] = [:]
    var arrived: (() -> Void)?

    func picture(_ address: String?, pixels: Int) -> OpaquePointer? {
        guard let address, address.hasPrefix("https://") else { return nil }
        let key = "\(pixels)|\(address)"
        if let surface = kept[key] { return surface }
        if let until = failedUntil[key] {
            guard ProcessInfo.processInfo.systemUptime >= until else { return nil }
            failedUntil[key] = nil
        }
        guard !loading.contains(key), let url = URL(string: address) else { return nil }
        loading.insert(key)
        let session = Self.session
        Task.detached {
            let answer = try? await session.plainData(from: url)
            let status = (answer?.1 as? HTTPURLResponse)?.statusCode ?? 0
            let data = (200..<300).contains(status) ? answer?.0 : nil
            await MainActor.run { self.decoded(data, key: key, pixels: pixels) }
        }
        return nil
    }

    private func decoded(_ data: Data?, key: String, pixels: Int) {
        loading.remove(key)
        guard let data, let surface = cairoSurface(data, maxPixels: Int32(pixels)) else {
            failedUntil[key] = ProcessInfo.processInfo.systemUptime + 60
            return
        }
        kept[key] = surface
        order.append(key)
        while order.count > 240 { let old = order.removeFirst(); if let gone = kept.removeValue(forKey: old) { cairo_surface_destroy(gone) } }
        arrived?()
    }
}

func cairoSurface(_ data: Data, maxPixels: Int32) -> OpaquePointer? {
    var width: Int32 = 0, height: Int32 = 0, stride: Int32 = 0
    guard let pixels = data.withUnsafeBytes({ con_image_decode($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count), maxPixels, &width, &height, &stride) }) else { return nil }
    let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)!
    cairo_surface_flush(surface)
    let target = cairo_image_surface_get_data(surface)!, targetStride = Int(cairo_image_surface_get_stride(surface))
    for row in 0..<Int(height) { memcpy(target + row * targetStride, pixels + row * Int(stride), Int(width) * 4) }
    cairo_surface_mark_dirty(surface)
    free(pixels)
    return surface
}
