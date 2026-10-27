import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var scanner = ScannerModel()

    var body: some View {
        VStack(spacing: 22) {
            MetalPointCloudView(renderer: scanner.renderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    Button("Frame") { scanner.renderer.frameRoom() }
                        .font(.system(size: 13))
                        .buttonStyle(.bordered)
                        .padding(8)
                }

            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 58, weight: .thin))
                .foregroundStyle(.tint)

            Text("Room Scanner")
                .font(.title2.bold())

            Text(scanner.statusText)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("\(scanner.pointCount.formatted())")
                .font(.system(size: 45, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("RGB points · 2 mm voxel grid")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(scanner.trackingOK ? .green : .orange)
                    .frame(width: 9, height: 9)
                Text(scanner.isScanning
                     ? (scanner.trackingOK ? "Tracking normal" : "Waiting for stable tracking")
                     : "Camera idle / paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if scanner.isExporting {
                ProgressView("Writing RGB PLY…")
                    .padding(.top, 4)
            }

            HStack(spacing: 12) {
                Button {
                    scanner.toggleScanning()
                } label: {
                    Label(scanner.isScanning ? "Pause" : (scanner.hasStarted ? "Resume" : "Scan"),
                          systemImage: scanner.isScanning ? "pause.fill" : "record.circle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    scanner.exportPLY()
                } label: {
                    Label("Export PLY", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(scanner.pointCount == 0 || scanner.isExporting)
            }

            Button(role: .destructive) {
                scanner.clear()
            } label: {
                Label("Clear scan", systemImage: "trash")
                    .font(.system(size: 13))
            }
            .disabled(scanner.pointCount == 0 || scanner.isExporting)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task { scanner.prepare() }
        .onDisappear { scanner.stop() }
        .alert("Room Scanner", isPresented: $scanner.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanner.alertMessage)
        }
        .sheet(isPresented: $scanner.showShareSheet) {
            if let url = scanner.exportURL {
                ShareSheet(items: [url])
            }
        }
    }
}

final class ScannerModel: ObservableObject {
    private let capture = ARCaptureService()
    private let fusion = VoxelMap()
    let renderer = PointCloudRenderer()
    private var statsTimer: Timer?
    private var renderRefreshBusy = false
    private var hasFramedFirstCloud = false

    @Published var isScanning = false
    @Published var hasStarted = false
    @Published var trackingOK = false
    @Published var pointCount = 0
    @Published var isExporting = false
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var showShareSheet = false
    @Published var exportURL: URL?

    var statusText: String {
        if isScanning { return "Scanning" }
        if hasStarted { return "Paused" }
        return "Ready · Tap Scan to start"
    }

    init() {
        capture.onPoints = { [weak self] points in
            self?.fusion.integrate(points)
        }
        capture.onTracking = { [weak self] ok in
            DispatchQueue.main.async {
                self?.trackingOK = ok
            }
        }
    }

    func prepare() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pointCount = self.fusion.count
            guard !self.renderRefreshBusy, self.pointCount > 0 else { return }
            self.renderRefreshBusy = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let all = self.fusion.snapshot()
                // Render at most ~100k evenly sampled points, while storing
                // and exporting the entire 2mm RGB point cloud.
                let step = max(1, (all.count + 99_999) / 100_000)
                let preview = Swift.stride(from: 0, to: all.count, by: step)
                    .map { all[$0] }
                self.renderer.update(points: preview)
                DispatchQueue.main.async {
                    if !self.hasFramedFirstCloud && preview.count > 200 {
                        self.renderer.frameRoom()
                        self.hasFramedFirstCloud = true
                    }
                    self.renderRefreshBusy = false
                }
            }
        }
    }

    func toggleScanning() {
        if isScanning {
            capture.pauseCapture()
            isScanning = false
        } else {
            if !hasStarted {
                capture.start()
                hasStarted = true
            } else {
                capture.resumeCapture()
            }
            isScanning = true
        }
    }

    func clear() {
        capture.pauseCapture()
        isScanning = false
        fusion.clear()
        renderer.update(points: [])
        renderer.resetCamera()
        hasFramedFirstCloud = false
        pointCount = 0
    }

    func stop() {
        capture.stop()
        isScanning = false
        statsTimer?.invalidate()
        statsTimer = nil
    }

    func exportPLY() {
        guard !isExporting else { return }
        isExporting = true
        // Export a consistent snapshot without blocking SwiftUI while writing.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let points = self.fusion.snapshot()
            guard !points.isEmpty else {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.alertMessage = "Scan some surfaces before exporting."
                    self.showAlert = true
                }
                return
            }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RoomScan-\(Int(Date().timeIntervalSince1970)).ply")
                try PLYWriter.write(points: points, to: url)
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.exportURL = url
                    self.showShareSheet = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.alertMessage = "Could not export RGB PLY: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


// Renderer and SwiftUI bridge are included in this file intentionally.
// This prevents missing target-membership references for PointCloudRenderer.swift.
import SwiftUI
import Foundation
import Metal
import MetalKit
import simd
import UIKit

struct RenderPoint {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

final class PointCloudRenderer: NSObject, ObservableObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let lock = NSLock()
    private var points: [RenderPoint] = []
    private var vertexBuffer: MTLBuffer?
    private var bufferDirty = true
    private var viewportSize = CGSize(width: 1, height: 1)

    private var target = SIMD3<Float>(0, 1, 0)
    private var azimuth: Float = 0
    private var elevation: Float = 0.15
    private var distance: Float = 3.0
    private var pan = SIMD3<Float>(repeating: 0)

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device.")
        }
        self.device = device
        self.commandQueue = queue

        let library = device.makeDefaultLibrary()!
        let vertex = library.makeFunction(name: "pointVertex")!
        let fragment = library.makeFunction(name: "pointFragment")!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float

        // SIMD3<Float> has 16-byte stride/alignment on Swift; match Metal float3 layout.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<RenderPoint>.stride
        descriptor.vertexDescriptor = vertexDescriptor

        self.pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

        super.init()
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
    }

    func update(points newPoints: [ColoredPoint]) {
        lock.lock()
        points = newPoints.map { RenderPoint(position: $0.position, color: $0.color) }
        bufferDirty = true
        lock.unlock()
    }

    func resetCamera() {
        lock.lock()
        target = SIMD3<Float>(0, 1, 0)
        azimuth = 0
        elevation = 0.15
        distance = 3
        pan = .zero
        lock.unlock()
    }

    func frameRoom() {
        lock.lock()
        defer { lock.unlock() }
        guard !points.isEmpty else {
            target = SIMD3<Float>(0, 1, 0)
            distance = 3
            return
        }
        var minP = points[0].position
        var maxP = points[0].position
        for p in points {
            minP = simd_min(minP, p.position)
            maxP = simd_max(maxP, p.position)
        }
        target = (minP + maxP) * 0.5
        let extent = maxP - minP
        distance = max(1.0, simd_length(extent) * 1.15)
        pan = .zero
    }

    func orbit(deltaX: Float, deltaY: Float) {
        lock.lock()
        azimuth -= deltaX * 0.008
        elevation = max(-1.45, min(1.45, elevation + deltaY * 0.008))
        lock.unlock()
    }

    func zoom(scale: Float) {
        lock.lock()
        distance = max(0.15, min(30, distance / max(0.2, scale)))
        lock.unlock()
    }

    func panCamera(deltaX: Float, deltaY: Float) {
        lock.lock()
        // Move the orbit target in the camera's image plane, independent of viewing angle.
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let up = SIMD3<Float>(
            -sin(elevation) * sin(azimuth),
             cos(elevation),
            -sin(elevation) * cos(azimuth)
        )
        let scale = 2 * distance * tan(Float.pi / 6) / Float(max(1, viewportSize.height))
        pan += right * (-deltaX * scale) + up * (deltaY * scale)
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer() else { return }

        lock.lock()
        if bufferDirty {
            let bytes = points.count * MemoryLayout<RenderPoint>.stride
            vertexBuffer = bytes > 0
            ? device.makeBuffer(length: bytes, options: .storageModeShared)
            : nil
            if let buffer = vertexBuffer, bytes > 0 {
                points.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { memcpy(buffer.contents(), base, bytes) }
                }
            }
            bufferDirty = false
        }
        let localBuffer = vertexBuffer
        let count = points.count
        let localTarget = target + pan
        let localAzimuth = azimuth
        let localElevation = elevation
        let localDistance = distance
        lock.unlock()

        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)

        if count > 0, let buffer = localBuffer {
            var camera = makeCamera(target: localTarget,
                                    azimuth: localAzimuth,
                                    elevation: localElevation,
                                    distance: localDistance,
                                    aspect: Float(max(1, viewportSize.width) / max(1, viewportSize.height)))
            encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func makeCamera(target: SIMD3<Float>, azimuth: Float, elevation: Float,
                            distance: Float, aspect: Float) -> CameraUniforms {
        let cp = cos(elevation)
        let eye = target + SIMD3<Float>(
            distance * cp * sin(azimuth),
            distance * sin(elevation),
            distance * cp * cos(azimuth)
        )
        let view = lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
        let projection = perspective(fovY: 60 * .pi / 180,
                                     aspect: max(0.1, aspect),
                                     near: 0.01, far: 100)
        return CameraUniforms(viewProjection: projection * view)
    }

    private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    private func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }
}

struct CameraUniforms {
    var viewProjection: simd_float4x4
}

struct MetalPointCloudView: UIViewRepresentable {
    let renderer: PointCloudRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        renderer.configure(view)
        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)
        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Two-finger translation and pinch may happen together.
            return gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        let renderer: PointCloudRenderer
        init(renderer: PointCloudRenderer) { self.renderer = renderer }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let d = gesture.translation(in: gesture.view)
            renderer.orbit(deltaX: Float(d.x), deltaY: Float(d.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc func twoFingerPan(_ gesture: UIPanGestureRecognizer) {
            let d = gesture.translation(in: gesture.view)
            renderer.panCamera(deltaX: Float(d.x), deltaY: Float(d.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            renderer.zoom(scale: Float(gesture.scale))
            gesture.scale = 1
        }
    }
}
