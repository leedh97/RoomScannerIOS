import Foundation

enum PLYWriter {
    // Mesh vertices are a triangle soup: every consecutive three form one face.
    // ASCII PLY preserves per-vertex RGB and explicit triangle connectivity.
    static func writeTriangleMesh(vertices: [ColoredPoint], to url: URL) throws {
        guard vertices.count % 3 == 0 else { throw MeshExportError.invalidTriangleCount }
        var data = Data()
        let header = """
        ply
        format ascii 1.0
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(vertices.count / 3)
        property list uchar int vertex_indices
        end_header

        """
        data.append(contentsOf: header.utf8)
        for point in vertices {
            let r = Int(max(0, min(255, point.color.x * 255)))
            let g = Int(max(0, min(255, point.color.y * 255)))
            let b = Int(max(0, min(255, point.color.z * 255)))
            data.append(contentsOf: "\(point.position.x) \(point.position.y) \(point.position.z) \(r) \(g) \(b)\n".utf8)
        }
        for i in stride(from: 0, to: vertices.count, by: 3) {
            data.append(contentsOf: "3 \(i) \(i + 1) \(i + 2)\n".utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    enum MeshExportError: Error { case invalidTriangleCount }

    static func write(points: [ColoredPoint], to url: URL) throws {
        var data = Data()
        let header = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        data.append(Data(header.utf8))
        for point in points {
            let r = Int(max(0, min(255, point.color.x * 255)))
            let g = Int(max(0, min(255, point.color.y * 255)))
            let b = Int(max(0, min(255, point.color.z * 255)))
            let line = "\(point.position.x) \(point.position.y) \(point.position.z) \(r) \(g) \(b)\n"
            data.append(Data(line.utf8))
        }
        try data.write(to: url, options: .atomic)
    }
}
