RoomScanner 2mm — Enlarged Live RGB Point Cloud Preview

Replace ContentView.swift in the existing Xcode project. It includes
PointCloudRenderer and MetalPointCloudView in the same file.
Do NOT also compile an old standalone PointCloudRenderer.swift, to avoid duplicate definitions.
Shaders.metal MUST exist on disk and be included in the RoomScanner target.

The Metal preview now expands to use all remaining screen height.
Scan status, point count, Scan/Pause/Resume, Export PLY and Clear controls
are condensed into two short rows below it. Frame stays overlaid.

Unchanged: 2mm voxel RGB fusion, 100k point preview cap, RGB PLY export,
ARKit VIO, depth filtering and conservative translation-only ICP.

Build not verified on Xcode/iPhone in this environment.
