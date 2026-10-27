import Foundation
import ARKit
import UIKit
import simd

struct ColoredPoint {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
    var confidence: Float
}

final class ARCaptureService: NSObject, ARSessionDelegate {
    private let session = ARSession()
    private let workQueue = DispatchQueue(label: "roomscanner.capture", qos: .userInitiated)
    private var paused = false
    private var lastAcceptedDepth: [Float] = []
    private var lastDepthWidth = 0
    private var lastDepthHeight = 0
    private var lastIntegratedTime: TimeInterval = 0
    private var lastPosition = SIMD3<Float>(repeating: .infinity)
    private var lastForward = SIMD3<Float>(repeating: .infinity)

    var onPoints: (([ColoredPoint]) -> Void)?
    var onTracking: ((Bool) -> Void)?

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            onTracking?(false)
            return
        }
        lastIntegratedTime = 0
        lastPosition = SIMD3<Float>(repeating: .infinity)
        lastForward = SIMD3<Float>(repeating: .infinity)
        lastAcceptedDepth = []
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    func pauseCapture() {
        paused = true
    }

    func resumeCapture() {
        paused = false
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let ok: Bool
        switch frame.camera.trackingState {
        case .normal: ok = true
        default: ok = false
        }
        onTracking?(ok)
        guard !paused, ok, let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let t = frame.timestamp
        let transform = frame.camera.transform
        let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        // Integrate at a modest rate and when viewpoint changes enough to add useful information.
        if t - lastIntegratedTime < 0.08 { return }
        if lastPosition.x.isFinite {
            let translation = simd_length(pos - lastPosition)
            let angle = acos(max(-1, min(1, simd_dot(simd_normalize(forward),
                                                     simd_normalize(lastForward)))))
            if translation < 0.025 && angle < 0.035 { return }
        }

        let previousPosition = lastPosition
        lastIntegratedTime = t
        lastPosition = pos
        lastForward = forward

        let depthMap = sceneDepth.depthMap
        
        guard let confidenceMap = sceneDepth.confidenceMap else {
            return
        }
        
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        let image = frame.capturedImage
        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap),
              CVPixelBufferGetBaseAddressOfPlane(image, 0) != nil,
              CVPixelBufferGetBaseAddressOfPlane(image, 1) != nil else { return }

        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let dRow = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let cRow = CVPixelBufferGetBytesPerRow(confidenceMap) / MemoryLayout<UInt8>.size
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confPtr = confidenceBase.assumingMemoryBound(to: UInt8.self)

        // Bi-planar YCbCr; convert sampled camera pixels to RGB.
        let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        // ARKit camera coordinates: +x right, +y up, camera looks along -z.
        // Intrinsics are expressed at captured-image resolution, so scale them to depth resolution.
        let sx = Float(dw) / Float(imageWidth)
        let sy = Float(dh) / Float(imageHeight)
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy

        // 1-pixel depth sampling; preserve 5mm world-space voxel fusion.
        let stride = 1
        var currentDepth = [Float](repeating: .nan, count: dw * dh)
        let hasPrevious = lastDepthWidth == dw && lastDepthHeight == dh
            && lastAcceptedDepth.count == dw * dh
        // Depth discontinuities and unstable returns should not create floating surfaces.
        // Temporal check is applied only when viewpoint motion is small.
        let temporalValid = hasPrevious && simd_length(pos - previousPosition) < 0.012
        var points: [ColoredPoint] = []
        points.reserveCapacity((dw / stride) * (dh / stride) / 2)

        for v in Swift.stride(from: 0, to: dh, by: stride) {
            for u in Swift.stride(from: 0, to: dw, by: stride) {
                let d = depthPtr[v * dRow + u]
                guard d.isFinite, d > 0.15, d < 8.0 else { continue }
                currentDepth[v * dw + u] = d
                if u > 0 && u + 1 < dw && v > 0 && v + 1 < dh {
                    let neighbors = [
                        depthPtr[v * dRow + u - 1],
                        depthPtr[v * dRow + u + 1],
                        depthPtr[(v - 1) * dRow + u],
                        depthPtr[(v + 1) * dRow + u]
                    ]
                    if neighbors.contains(where: { !$0.isFinite || abs($0 - d) > max(0.035, d * 0.025) }) {
                        continue
                    }
                }
                if temporalValid {
                    let old = lastAcceptedDepth[v * dw + u]
                    if old.isFinite && abs(old - d) > max(0.055, d * 0.04) {
                        continue
                    }
                }

                let confidence = confPtr[v * cRow + u]
                guard confidence >= ARConfidenceLevel.medium.rawValue else { continue }

                let x = (Float(u) - cx) * d / fx
                let y = -(Float(v) - cy) * d / fy
                let cameraPoint = SIMD4<Float>(x, y, -d, 1)
                let world = cameraTransform * cameraPoint
                let position = SIMD3<Float>(world.x, world.y, world.z)

                // Map depth pixel to captured-image pixel for color sampling.
                let ix = min(max(Int(Float(u) / sx), 0), imageWidth - 1)
                let iy = min(max(Int(Float(v) / sy), 0), imageHeight - 1)
                let yValue = Float(yBase[iy * yStride + ix])
                let uvx = min(max(ix / 2, 0), CVPixelBufferGetWidthOfPlane(image, 1) - 1)
                let uvy = min(max(iy / 2, 0), CVPixelBufferGetHeightOfPlane(image, 1) - 1)
                let cb = Float(cbcrBase[uvy * cbcrStride + uvx * 2]) - 128
                let cr = Float(cbcrBase[uvy * cbcrStride + uvx * 2 + 1]) - 128

                let r = max(0, min(255, yValue + 1.5748 * cr))
                let g = max(0, min(255, yValue - 0.1873 * cb - 0.4681 * cr))
                let b = max(0, min(255, yValue + 1.8556 * cb))
                let color = SIMD3<Float>(r / 255, g / 255, b / 255)

                points.append(ColoredPoint(
                    position: position,
                    color: color,
                    confidence: confidence == ARConfidenceLevel.high.rawValue ? 1.0 : 0.5
                ))
            }
        }

        if !points.isEmpty {
            lastAcceptedDepth = currentDepth
            lastDepthWidth = dw
            lastDepthHeight = dh
            onPoints?(points)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onTracking?(false)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        start()
    }
}

// ARKit scene reconstruction supplies geometry independent of the RGB depth points.
extension ARCaptureService {
}
