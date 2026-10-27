FIX FOR missing MetalPointCloudView / PointCloudRenderer / ObservedObject errors

1. Back up your existing project.
2. Replace RoomScanner/ContentView.swift with the one in this ZIP.
   This ContentView.swift INCLUDES PointCloudRenderer and MetalPointCloudView.
3. IMPORTANT: REMOVE PointCloudRenderer.swift from the Xcode target
   (or delete the old file) to avoid duplicate type declarations.
4. Copy Shaders.metal into RoomScanner/ and ensure it belongs to the
   RoomScanner target (File Inspector > Target Membership).
5. Replace ARCaptureService.swift, VoxelMap.swift and PLYWriter.swift.
6. Product > Clean Build Folder, then Build.

The previous errors were caused by renderer/view declarations not being
included in the Xcode target. Merging them into ContentView.swift makes
these types visible whenever ContentView itself is compiled.

Features: 2mm RGB voxel fusion, ARKit VIO, filtered depth, conservative
translation-only ICP, live RGB point preview, RGB PLY export. No mesh.

No macOS/Xcode/iPhone compile test was possible in this environment.
