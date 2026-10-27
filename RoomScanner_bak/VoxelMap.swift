import Foundation
import simd

struct VoxelKey: Hashable {
    let x: Int32
    let y: Int32
    let z: Int32
}

private struct VoxelValue {
    var positionSum: SIMD3<Float>
    var colorSum: SIMD3<Float>
    var weightSum: Float
    var observations: UInt32

    var point: ColoredPoint {
        let inv = 1 / max(weightSum, 0.0001)
        return ColoredPoint(position: positionSum * inv,
                            color: colorSum * inv,
                            confidence: min(1, weightSum / 4))
    }
}

final class VoxelMap {
    private let queue = DispatchQueue(label: "roomscanner.voxelmap", qos: .userInitiated)
    private var map: [VoxelKey: VoxelValue] = [:]
    private let voxelSize: Float = 0.002
    private let maximumVoxels = 3_000_000

    var count: Int {
        queue.sync { map.count }
    }

    // Translation-only, gated scan-to-map ICP. ARKit VIO supplies rotation.
    // Deliberately avoids trying to estimate unobservable in-plane motion from
    // a single planar patch, and rejects corrections that do not reduce error.
    private func registered(_ points: [ColoredPoint]) -> [ColoredPoint] {
        guard map.count > 3_000, points.count > 500 else { return points }

        let cell: Float = 0.025
        func key(_ p: SIMD3<Float>) -> VoxelKey {
            VoxelKey(x: Int32(floor(p.x / cell)),
                     y: Int32(floor(p.y / cell)),
                     z: Int32(floor(p.z / cell)))
        }

        var grid: [VoxelKey: [SIMD3<Float>]] = [:]
        let mapStep = max(1, map.count / 45_000)
        for (i, item) in map.enumerated() where i % mapStep == 0 {
            let p = item.value.point.position
            grid[key(p), default: []].append(p)
        }

        let stride = max(1, points.count / 1_000)
        let sample = Swift.stride(from: 0, to: points.count, by: stride)
            .map { points[$0].position }
        guard sample.count >= 150 else { return points }

        func correspondences(_ offset: SIMD3<Float>) -> [(SIMD3<Float>, SIMD3<Float>, Float)] {
            var pairs: [(SIMD3<Float>, SIMD3<Float>, Float)] = []
            for original in sample {
                let p = original + offset
                let base = key(p)
                var best = SIMD3<Float>(repeating: 0)
                var bestD2: Float = 0.04 * 0.04
                for dz in -2...2 {
                    for dy in -2...2 {
                        for dx in -2...2 {
                            let k = VoxelKey(x: base.x + Int32(dx),
                                             y: base.y + Int32(dy),
                                             z: base.z + Int32(dz))
                            guard let bucket = grid[k] else { continue }
                            for candidate in bucket {
                                let d2 = simd_length_squared(candidate - p)
                                if d2 < bestD2 {
                                    bestD2 = d2
                                    best = candidate
                                }
                            }
                        }
                    }
                }
                if bestD2 < 0.04 * 0.04 {
                    pairs.append((p, best, bestD2))
                }
            }
            return pairs
        }

        let initial = correspondences(.zero)
        guard initial.count >= 120,
              Float(initial.count) / Float(sample.count) >= 0.35 else { return points }

        // Reject almost-planar/linear geometry: it cannot constrain full 3D alignment.
        let center = initial.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.1 }
            / Float(initial.count)
        var spread = SIMD3<Float>(repeating: 0)
        for pair in initial {
            let d = pair.1 - center
            spread += d * d
        }
        spread /= Float(initial.count)
        let sorted = [spread.x, spread.y, spread.z].sorted()
        guard sorted[0] > 0.00010 && sorted[1] > 0.001 else { return points }

        let initialRMSE = sqrt(initial.reduce(Float(0)) { $0 + $1.2 } / Float(initial.count))
        var offset = SIMD3<Float>(repeating: 0)
        var pairs = initial
        for _ in 0..<4 {
            guard pairs.count >= 120 else { return points }
            // Trim the worst 25% of correspondences to reduce edge/outlier bias.
            pairs.sort { $0.2 < $1.2 }
            let kept = pairs.prefix(max(120, pairs.count * 3 / 4))
            let delta = kept.reduce(SIMD3<Float>(repeating: 0)) {
                $0 + ($1.1 - $1.0)
            } / Float(kept.count)
            if simd_length(delta) > 0.012 { return points }
            offset += delta
            if simd_length(offset) > 0.020 { return points }
            if simd_length(delta) < 0.0005 { break }
            pairs = correspondences(offset)
        }
        let finalPairs = correspondences(offset)
        guard finalPairs.count >= 120 else { return points }
        let finalRMSE = sqrt(finalPairs.reduce(Float(0)) { $0 + $1.2 }
                             / Float(finalPairs.count))
        guard finalRMSE < initialRMSE * 0.92,
              finalRMSE < 0.018,
              Float(finalPairs.count) / Float(sample.count) >= 0.35 else {
            return points
        }
        return points.map {
            ColoredPoint(position: $0.position + offset,
                         color: $0.color, confidence: $0.confidence)
        }
    }

    func integrate(_ points: [ColoredPoint]) {
        queue.async { [weak self] in
            guard let self else { return }
            let corrected = self.registered(points)
            for point in corrected {
                let p = point.position
                let key = VoxelKey(
                    x: Int32(floor(p.x / self.voxelSize)),
                    y: Int32(floor(p.y / self.voxelSize)),
                    z: Int32(floor(p.z / self.voxelSize))
                )
                let w = max(0.1, point.confidence)
                if var old = self.map[key] {
                    let effectiveWeight = min(w, 2.0)
                    old.positionSum += point.position * effectiveWeight
                    old.colorSum += point.color * effectiveWeight
                    old.weightSum += effectiveWeight
                    old.observations &+= 1
                    if old.weightSum > 32 {
                        old.positionSum *= 0.5
                        old.colorSum *= 0.5
                        old.weightSum *= 0.5
                    }
                    self.map[key] = old
                } else if self.map.count < self.maximumVoxels {
                    self.map[key] = VoxelValue(
                        positionSum: point.position * w,
                        colorSum: point.color * w,
                        weightSum: w,
                        observations: 1
                    )
                }
            }
        }
    }

    func snapshot() -> [ColoredPoint] {
        queue.sync { map.values.map(\.point) }
    }

    func clear() {
        queue.sync { map.removeAll(keepingCapacity: false) }
    }
}


