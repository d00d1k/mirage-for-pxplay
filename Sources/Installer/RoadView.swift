import MetalKit
import SwiftUI

/// A neon road at dusk, drawn procedurally on the GPU (no footage or artwork).
/// `clarity` 0 → choppy 15 fps, pixelated and blurred; 1 → sharp, smooth 60 fps.
struct RoadView: NSViewRepresentable {
    var clarity: Double

    func makeCoordinator() -> RoadRenderer { RoadRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.delegate = context.coordinator
        view.layer?.isOpaque = true
        context.coordinator.clarity = clarity
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.clarity = clarity
    }
}

final class RoadRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let start = CACurrentMediaTime()
    private var lastDraw: CFTimeInterval = 0
    var clarity: Double = 1

    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var blur: Float
        var pixel: Float
        var pad: Float = 0
    }

    override init() {
        queue = device?.makeCommandQueue()
        super.init()
        guard let device else { return }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: RoadRenderer.shader, options: nil)
        } catch {
            fputs("Mirage Installer: scene shader failed: \(error)\n", stderr)
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "roadVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "roadFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let c = max(0, min(1, clarity))
        let fps = 15 + 45 * pow(c, 1.4)
        // Skipping a draw leaves the previous frame on screen: that is the choppy start.
        guard now - lastDraw >= 1 / fps - 0.002 else { return }
        lastDraw = now
        guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = Float(view.drawableSize.height / max(view.bounds.height, 1))
        var uniforms = Uniforms(resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                time: Float(now - start), blur: Float(1 - c) * 9 * scale,
                                pixel: max(1, Float(1 - c) * 7 * scale))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 resolution; float time; float blur; float pixel; float pad; };
    struct Out { float4 position [[position]]; };

    vertex Out roadVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Out o; o.position = float4(p * 2.0 - 1.0, 0, 1); return o;
    }

    static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

    static float roundBox(float2 p, float2 b, float r) {
        float2 d = abs(p) - (b - r);
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
    }

    // A retro coupe seen from behind (chase camera), in view-height units. Dark paint with
    // the sunset on its edges and rear window, a full-width tail light bar and two lamps.
    static float3 drawCar(float3 col, float x, float y, float t) {
        const float aa = 0.0016;
        float2 p = float2(x, y - (0.205 + 0.0012 * sin(t * 11.0)));
        col *= 1.0 - 0.75 * exp(-pow(x / 0.14, 2.0) - pow((y - 0.163) / 0.011, 2.0));
        float wheels = min(roundBox(p - float2(-0.088, -0.031), float2(0.021, 0.017), 0.006),
                           roundBox(p - float2(0.088, -0.031), float2(0.021, 0.017), 0.006));
        float body = roundBox(p, float2(0.118, 0.031), 0.013);
        float2 c = p - float2(0.0, 0.051);
        float halfW = 0.08 - (c.y + 0.022) * 0.5;
        float cabin = max(abs(c.x) - halfW, abs(c.y) - 0.022);
        float shape = min(min(body, cabin), wheels);
        float inside = 1.0 - smoothstep(-aa, aa, shape);
        float3 car = mix(float3(0.03, 0.02, 0.07), float3(0.09, 0.05, 0.16), clamp(p.y / 0.07 + 0.5, 0.0, 1.0));
        float window = max(abs(c.x) - (halfW - 0.009), abs(c.y - 0.003) - 0.013);
        float glass = 1.0 - smoothstep(-aa, aa, window);
        float3 sky = mix(float3(0.95, 0.42, 0.38), float3(0.42, 0.14, 0.48), clamp((c.y + 0.01) / 0.028, 0.0, 1.0));
        car = mix(car, sky * 0.6, glass);
        float rim = exp(-abs(body) * 1100.0) * smoothstep(0.0, 0.02, p.y) + exp(-abs(cabin) * 1100.0) * step(-0.016, c.y);
        car += rim * float3(1.0, 0.45, 0.72) * 0.55;
        float bar = 1.0 - smoothstep(0.0, aa * 1.5, roundBox(p - float2(0.0, 0.009), float2(0.1, 0.0035), 0.0035));
        float lamps = 1.0 - smoothstep(0.0, aa * 1.5, min(roundBox(p - float2(-0.089, 0.009), float2(0.021, 0.0085), 0.004),
                                                          roundBox(p - float2(0.089, 0.009), float2(0.021, 0.0085), 0.004)));
        car = mix(car, float3(1.0, 0.13, 0.22), max(bar * 0.8, lamps));
        float plate = 1.0 - smoothstep(0.0, aa, roundBox(p - float2(0.0, -0.013), float2(0.022, 0.0065), 0.002));
        car = mix(car, float3(0.72, 0.7, 0.8), plate * 0.75);
        col = mix(col, car, inside);
        float2 l1 = p - float2(-0.089, 0.009), l2 = p - float2(0.089, 0.009);
        col += float3(1.0, 0.1, 0.25) * (exp(-dot(l1, l1) * 1200.0) + exp(-dot(l2, l2) * 1200.0)) * 0.4;
        col += float3(1.0, 0.1, 0.25) * exp(-pow(p.x / 0.13, 2.0) - pow((p.y - 0.009) / 0.012, 2.0)) * 0.12;
        return col;
    }

    static float3 scene(float2 frag, float2 res, float t) {
        float aspect = res.x / res.y;
        float2 uv = float2(frag.x / res.x, 1.0 - frag.y / res.y);   // y up
        float x = (uv.x - 0.5) * aspect;                           // centred, aspect-correct
        const float horizon = 0.40;
        float3 col;
        if (uv.y >= horizon) {
            float h = (uv.y - horizon) / (1.0 - horizon);
            col = mix(float3(1.00, 0.45, 0.32), float3(0.86, 0.22, 0.52), smoothstep(0.0, 0.25, h));
            col = mix(col, float3(0.36, 0.13, 0.55), smoothstep(0.2, 0.6, h));
            col = mix(col, float3(0.07, 0.05, 0.18), smoothstep(0.55, 1.0, h));
            float2 cell = floor(float2(x, uv.y) * 90.0);
            float star = step(0.985, hash(cell)) * smoothstep(0.45, 0.9, h);
            col += star * (0.5 + 0.5 * sin(t * 3.0 + hash(cell + 3.1) * 40.0)) * float3(0.9, 0.85, 1.0);
            float2 sc = float2(0.0, horizon + 0.17);
            float d = length(float2(x, uv.y) - sc);
            float r = 0.24;
            float glow = exp(-max(d - r, 0.0) * 9.0);
            col += float3(1.0, 0.35, 0.55) * glow * 0.35;
            if (d < r) {
                float k = (uv.y - (sc.y - r)) / (2.0 * r);
                float3 sun = mix(float3(1.0, 0.25, 0.45), float3(1.0, 0.86, 0.42), k);
                float band = fract((sc.y - uv.y) * 22.0 + t * 0.35);
                float gap = (uv.y < sc.y) ? step(band, 0.18 + 0.5 * (sc.y - uv.y) / r) : 0.0;
                col = mix(sun, col, gap);
            }
            float m = horizon + 0.045 + 0.035 * sin(x * 7.0 + 1.3) + 0.02 * sin(x * 17.0 + 0.4) + 0.01 * sin(x * 41.0);
            m = max(m, horizon + 0.004);
            if (uv.y < m) {
                col = mix(float3(0.10, 0.04, 0.20), float3(0.18, 0.06, 0.30), (uv.y - horizon) / (m - horizon));
                col += float3(1.0, 0.3, 0.7) * exp(-(m - uv.y) * 160.0) * 0.6;
            }
        } else {
            float z = (horizon - uv.y) / horizon;          // 0 at horizon, 1 at the bottom
            float depth = 1.0 / max(z, 0.002);
            float gx = x * depth * 0.6;
            float gz = depth * 0.9 - t * 2.4;
            float lineW = 0.035 * depth * 0.25 + 0.02;
            float grid = max(1.0 - smoothstep(0.0, lineW, abs(fract(gx) - 0.5) - (0.5 - lineW)),
                             1.0 - smoothstep(0.0, lineW * 1.6, abs(fract(gz) - 0.5) - (0.5 - lineW * 1.6)));
            col = mix(float3(0.03, 0.02, 0.09), float3(0.12, 0.04, 0.22), z);
            col += grid * float3(1.0, 0.25, 0.75) * (0.25 + 0.75 * z);
            float road = 0.03 + 0.42 * z;
            float ax = abs(x);
            if (ax < road) {
                col = mix(float3(0.04, 0.03, 0.08), float3(0.09, 0.07, 0.14), z);
                float dash = step(fract(depth * 0.55 - t * 3.2), 0.5);
                col += dash * (1.0 - smoothstep(0.004 + 0.012 * z, 0.008 + 0.016 * z, ax)) * float3(1.0, 0.82, 0.35);
                col += (1.0 - smoothstep(0.0, 0.006 + 0.01 * z, road - ax)) * float3(0.3, 0.9, 1.0) * 0.9;
            }
            col = mix(col, float3(0.8, 0.3, 0.6), exp(-z * 18.0) * 0.6);
            col = drawCar(col, x, uv.y, t);
        }
        return col;
    }

    fragment float4 roadFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 frag = (floor(in.position.xy / u.pixel) + 0.5) * u.pixel;
        float3 col = float3(0);
        if (u.blur < 0.5) {
            col = scene(frag, u.resolution, u.time);
        } else {
            const int taps = 12;
            for (int i = 0; i < taps; i++) {
                float a = float(i) * 2.39996;
                float r = u.blur * sqrt((float(i) + 0.5) / float(taps));
                col += scene(frag + float2(cos(a), sin(a)) * r, u.resolution, u.time);
            }
            col /= float(taps);
        }
        float2 v = in.position.xy / u.resolution - 0.5;
        col *= 1.0 - dot(v, v) * 0.6;
        return float4(pow(col, float3(0.95)), 1.0);
    }
    """
}
