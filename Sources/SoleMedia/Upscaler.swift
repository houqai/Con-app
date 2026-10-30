import CoreVideo
import Foundation
import Metal
import MetalFX
import SoleCore

final class Upscaler {
    enum Failure: Error { case unsupported, setup }

    private final class Slot {
        let size: [Int]
        var textures: [String: MTLTexture] = [:]
        var scaler: MTLFXSpatialScaler?
        var pool: CVPixelBufferPool?
        init(size: [Int]) { self.size = size }
    }

    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var cache: CVMetalTextureCache?
    private var slots: [Slot] = []
    private static let keptSizes = 2

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { throw Failure.unsupported }
        let library = try device.makeLibrary(source: Self.shader + Anime4KShader.source, options: nil)
        var made: [String: MTLComputePipelineState] = [:]
        for name in ["colour", "easu", "rcas", "anime4k_space"] + Anime4KShader.passes {
            guard let function = library.makeFunction(name: name) else { throw Failure.setup }
            made[name] = try device.makeComputePipelineState(function: function)
        }
        self.device = device; self.commands = commands; pipelines = made
        let attributes = [kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue)] as CFDictionary
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, attributes, &cache) == kCVReturnSuccess else { throw Failure.setup }
    }

    var hasMetalFX: Bool { MTLFXSpatialScalerDescriptor.supportsDevice(device) }

    static func easuConstants(input: (Int, Int), output: (Int, Int)) -> [Float] {
        let (iw, ih, ow, oh) = (Float(input.0), Float(input.1), Float(output.0), Float(output.1))
        return [iw / ow, ih / oh, 0.5 * iw / ow - 0.5, 0.5 * ih / oh - 0.5,
                1 / iw, 1 / ih, 1 / iw, -1 / ih,
                -1 / iw, 2 / ih, 1 / iw, 2 / ih,
                0, 4 / ih, 0, 0]
    }
    static let rcasStops = 0.2

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    static float3 rgb(float luma, float2 chroma) {
        float y = (luma * 255.0 - 16.0) / 219.0;
        float2 c = (chroma * 255.0 - 128.0) / 224.0;
        return saturate(float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x));
    }

    kernel void colour(texture2d<float, access::read> luma [[texture(0)]],
                       texture2d<float, access::sample> chroma [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       uint2 at [[thread_position_in_grid]]) {
        if (at.x >= out.get_width() || at.y >= out.get_height()) return;
        constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 place = (float2(at) + 0.5) / float2(out.get_width(), out.get_height());
        out.write(float4(rgb(luma.read(at).r, chroma.sample(smooth, place).rg), 1.0), at);
    }

    // ---- AMD FidelityFX Super Resolution 1 (ffx_fsr1.h, MIT, Copyright (c) 2021 Advanced Micro
    // Devices, Inc.), ported: EASU and RCAS of 32-bit floats, their approximations kept.

    static float rcpLow(float a) { return as_type<float>(0x7ef07ebbu - as_type<uint>(a)); }
    static float rcpMedium(float a) { float b = as_type<float>(0x7ef19fffu - as_type<uint>(a)); return b * (-b * a + 2.0); }
    static float rsqLow(float a) { return as_type<float>(0x5f347d74u - (as_type<uint>(a) >> 1)); }

    static void easuTap(thread float3 &aC, thread float &aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {
        float2 v = float2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;
        float d2 = min(v.x * v.x + v.y * v.y, clp);
        float wB = 2.0 / 5.0 * d2 - 1.0, wA = lob * d2 - 1.0;
        wB *= wB; wA *= wA;
        wB = 25.0 / 16.0 * wB - (25.0 / 16.0 - 1.0);
        float w = wB * wA;
        aC += c * w; aW += w;
    }

    static void easuSet(thread float2 &dir, thread float &len, float2 pp, int corner, float lA, float lB, float lC, float lD, float lE) {
        float w = corner == 0 ? (1.0 - pp.x) * (1.0 - pp.y) : corner == 1 ? pp.x * (1.0 - pp.y) : corner == 2 ? (1.0 - pp.x) * pp.y : pp.x * pp.y;
        float dc = lD - lC, cb = lC - lB;
        float lenX = rcpLow(max(abs(dc), abs(cb)));
        float dirX = lD - lB;
        dir.x += dirX * w;
        lenX = saturate(abs(dirX) * lenX); lenX *= lenX;
        len += lenX * w;
        float ec = lE - lC, ca = lC - lA;
        float lenY = rcpLow(max(abs(ec), abs(ca)));
        float dirY = lE - lA;
        dir.y += dirY * w;
        lenY = saturate(abs(dirY) * lenY); lenY *= lenY;
        len += lenY * w;
    }

    struct EasuConstants { float4 con0; float4 con1; float4 con2; float4 con3; };

    kernel void easu(texture2d<float, access::sample> source [[texture(0)]],
                     texture2d<float, access::write> out [[texture(1)]],
                     constant EasuConstants &k [[buffer(0)]],
                     uint2 ip [[thread_position_in_grid]]) {
        if (ip.x >= out.get_width() || ip.y >= out.get_height()) return;
        constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
        float2 pp = float2(ip) * k.con0.xy + k.con0.zw;
        float2 fp = floor(pp);
        pp -= fp;
        float2 p0 = fp * k.con1.xy + k.con1.zw;
        float2 p1 = p0 + k.con2.xy, p2 = p0 + k.con2.zw, p3 = p0 + k.con3.xy;
        float4 bczzR = source.gather(s, p0, int2(0), component::x), bczzG = source.gather(s, p0, int2(0), component::y), bczzB = source.gather(s, p0, int2(0), component::z);
        float4 ijfeR = source.gather(s, p1, int2(0), component::x), ijfeG = source.gather(s, p1, int2(0), component::y), ijfeB = source.gather(s, p1, int2(0), component::z);
        float4 klhgR = source.gather(s, p2, int2(0), component::x), klhgG = source.gather(s, p2, int2(0), component::y), klhgB = source.gather(s, p2, int2(0), component::z);
        float4 zzonR = source.gather(s, p3, int2(0), component::x), zzonG = source.gather(s, p3, int2(0), component::y), zzonB = source.gather(s, p3, int2(0), component::z);
        float4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG), ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
        float4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG), zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);
        float bL = bczzL.x, cL = bczzL.y, iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
        float kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w, oL = zzonL.z, nL = zzonL.w;
        float2 dir = float2(0.0); float len = 0.0;
        easuSet(dir, len, pp, 0, bL, eL, fL, gL, jL);
        easuSet(dir, len, pp, 1, cL, fL, gL, hL, kL);
        easuSet(dir, len, pp, 2, fL, iL, jL, kL, nL);
        easuSet(dir, len, pp, 3, gL, jL, kL, lL, oL);
        float2 dir2 = dir * dir;
        float dirR = dir2.x + dir2.y;
        bool zro = dirR < 1.0 / 32768.0;
        dirR = rsqLow(dirR);
        dirR = zro ? 1.0 : dirR;
        dir.x = zro ? 1.0 : dir.x;
        dir *= dirR;
        len = len * 0.5; len *= len;
        float stretch = (dir.x * dir.x + dir.y * dir.y) * rcpLow(max(abs(dir.x), abs(dir.y)));
        float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
        float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
        float clp = rcpLow(lob);
        float3 f = float3(ijfeR.z, ijfeG.z, ijfeB.z), g = float3(klhgR.w, klhgG.w, klhgB.w), j = float3(ijfeR.y, ijfeG.y, ijfeB.y), kk = float3(klhgR.x, klhgG.x, klhgB.x);
        float3 min4 = min(min(min(f, g), j), kk), max4 = max(max(max(f, g), j), kk);
        float3 aC = float3(0.0); float aW = 0.0;
        easuTap(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x));
        easuTap(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y));
        easuTap(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x));
        easuTap(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, j);
        easuTap(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, f);
        easuTap(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w));
        easuTap(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, kk);
        easuTap(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y));
        easuTap(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z));
        easuTap(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, g);
        easuTap(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z));
        easuTap(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w));
        out.write(float4(min(max4, max(min4, aC / aW)), 1.0), ip);
    }

    kernel void rcas(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> out [[texture(1)]],
                     constant float &sharpness [[buffer(0)]],
                     uint2 ip [[thread_position_in_grid]]) {
        int w = out.get_width(), h = out.get_height();
        if (int(ip.x) >= w || int(ip.y) >= h) return;
        int2 sp = int2(ip), last = int2(w, h) - 1;
        float3 b = source.read(uint2(clamp(sp + int2(0, -1), int2(0), last))).rgb;
        float3 d = source.read(uint2(clamp(sp + int2(-1, 0), int2(0), last))).rgb;
        float3 e = source.read(uint2(sp)).rgb;
        float3 f = source.read(uint2(clamp(sp + int2(1, 0), int2(0), last))).rgb;
        float3 hh = source.read(uint2(clamp(sp + int2(0, 1), int2(0), last))).rgb;
        float bL = b.b * 0.5 + (b.r * 0.5 + b.g), dL = d.b * 0.5 + (d.r * 0.5 + d.g), eL = e.b * 0.5 + (e.r * 0.5 + e.g);
        float fL = f.b * 0.5 + (f.r * 0.5 + f.g), hL = hh.b * 0.5 + (hh.r * 0.5 + hh.g);
        float nz = 0.25 * bL + 0.25 * dL + 0.25 * fL + 0.25 * hL - eL;
        nz = saturate(abs(nz) * rcpMedium(max(max(max(bL, dL), max(eL, fL)), hL) - min(min(min(bL, dL), min(eL, fL)), hL)));
        nz = -0.5 * nz + 1.0;
        float3 mn4 = min(min(min(b, d), f), hh), mx4 = max(max(max(b, d), f), hh);
        float3 hitMin = min(mn4, e) / (4.0 * mx4);
        float3 hitMax = (1.0 - max(mx4, e)) / (4.0 * mn4 - 4.0);
        float3 lobes = max(-hitMin, hitMax);
        float lobe = max(-(0.25 - 1.0 / 16.0), min(max(max(lobes.r, lobes.g), lobes.b), 0.0)) * sharpness;
        lobe *= nz;
        float rcpL = rcpMedium(4.0 * lobe + 1.0);
        out.write(float4((lobe * (b + d + hh + f) + e) * rcpL, 1.0), ip);
    }
    """

    func scale(_ picture: CVPixelBuffer, width: Int, height: Int, method: Upscale.Method = .fsr) -> CVPixelBuffer? {
        guard let cache, CVPixelBufferGetPlaneCount(picture) == 2 else { return nil }
        let inWidth = CVPixelBufferGetWidth(picture), inHeight = CVPixelBufferGetHeight(picture)
        let slot = self.slot(for: [inWidth, inHeight, width, height])
        guard preparePool(slot, width: width, height: height), let pool = slot.pool else { return nil }
        func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
            let planar = CVPixelBufferGetPlaneCount(buffer) > 0
            let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
            let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            var made: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format, w, h, plane, &made) == kCVReturnSuccess,
                  let made, let texture = CVMetalTextureGetTexture(made) else { return nil }
            return (made, texture)
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess, let output,
              let luma = texture(picture, plane: 0, format: .r8Unorm), let chroma = texture(picture, plane: 1, format: .rg8Unorm),
              let target = texture(output, plane: 0, format: .bgra8Unorm),
              let rgb = scratchTexture(slot, "rgb", inWidth, inHeight, .rgba8Unorm),
              let buffer = commands.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        func run(_ name: String, _ textures: [MTLTexture], size: (Int, Int), bytes: [Float] = []) {
            guard let pipeline = pipelines[name] else { return }
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            if !bytes.isEmpty { encoder.setBytes(bytes, length: bytes.count * MemoryLayout<Float>.size, index: 0) }
            encoder.dispatchThreadgroups(MTLSize(width: (size.0 + 15) / 16, height: (size.1 + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        run("colour", [luma.1, chroma.1, rgb], size: (inWidth, inHeight))
        var worked = true
        switch method {
        case .metalFX where hasMetalFX:
            encoder.endEncoding()
            if prepareScaler(slot, inWidth: inWidth, inHeight: inHeight, outWidth: width, outHeight: height), let scaler = slot.scaler, let scaled = slot.textures["scaled"] {
                scaler.colorTexture = rgb; scaler.outputTexture = scaled
                scaler.inputContentWidth = inWidth; scaler.inputContentHeight = inHeight
                scaler.encode(commandBuffer: buffer)
                if let blit = buffer.makeBlitCommandEncoder() { blit.copy(from: scaled, to: target.1); blit.endEncoding() } else { worked = false }
            } else { worked = false }
        case .anime4k:
            var input = rgb, size = (inWidth, inHeight), level = 0
            while size.0 * 2 <= width, size.1 * 2 <= height {
                let next = (size.0 * 2, size.1 * 2), last = next == (width, height)
                guard let a = scratchTexture(slot, "a\(level)", size.0, size.1, .rgba16Float), let b = scratchTexture(slot, "b\(level)", size.0, size.1, .rgba16Float),
                      let out = last ? target.1 : scratchTexture(slot, "doubled\(level)", next.0, next.1, .rgba8Unorm) else { worked = false; break }
                var detail = input, into = a
                for name in Anime4KShader.passes {
                    run(name, [detail, into], size: size)
                    detail = into; into = into === a ? b : a
                }
                run("anime4k_space", [detail, out, input], size: next)
                input = out; size = next; level += 1
            }
            if worked, size != (width, height) || level == 0 {
                run("easu", [input, target.1], size: (width, height), bytes: Self.easuConstants(input: size, output: (width, height)))
            }
            encoder.endEncoding()
        default:
            let sharpness = [Float(exp2(-Self.rcasStops))]
            if (width, height) == (inWidth, inHeight) {
                run("rcas", [rgb, target.1], size: (width, height), bytes: sharpness)
            } else if let big = scratchTexture(slot, "big", width, height, .rgba8Unorm) {
                run("easu", [rgb, big], size: (width, height), bytes: Self.easuConstants(input: (inWidth, inHeight), output: (width, height)))
                run("rcas", [big, target.1], size: (width, height), bytes: sharpness)
            } else { worked = false }
            encoder.endEncoding()
        }
        guard worked else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        withExtendedLifetime((luma.0, chroma.0, target.0)) {}
        return output
    }

    func release() {
        slots = []
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    private func slot(for size: [Int]) -> Slot {
        if let index = slots.firstIndex(where: { $0.size == size }) {
            let found = slots.remove(at: index)
            slots.append(found)
            return found
        }
        let made = Slot(size: size)
        slots.append(made)
        if slots.count > Self.keptSizes { slots.removeFirst(slots.count - Self.keptSizes) }
        return made
    }

    private func scratchTexture(_ slot: Slot, _ name: String, _ width: Int, _ height: Int, _ format: MTLPixelFormat) -> MTLTexture? {
        if let texture = slot.textures[name], texture.width == width, texture.height == height, texture.pixelFormat == format { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        slot.textures[name] = texture
        return texture
    }

    private func prepareScaler(_ slot: Slot, inWidth: Int, inHeight: Int, outWidth: Int, outHeight: Int) -> Bool {
        if slot.scaler != nil { return true }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inWidth; descriptor.inputHeight = inHeight
        descriptor.outputWidth = outWidth; descriptor.outputHeight = outHeight
        descriptor.colorTextureFormat = .rgba8Unorm; descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let made = descriptor.makeSpatialScaler(device: device) else { return false }
        let output = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outWidth, height: outHeight, mipmapped: false)
        output.usage = made.outputTextureUsage; output.storageMode = .private
        guard let scaled = device.makeTexture(descriptor: output) else { return false }
        slot.scaler = made; slot.textures["scaled"] = scaled
        return true
    }

    private func preparePool(_ slot: Slot, width: Int, height: Int) -> Bool {
        if slot.pool != nil { return true }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var made: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made) == kCVReturnSuccess else { return false }
        slot.pool = made
        return true
    }
}
