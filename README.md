# RoomScannerIOS

Native SwiftUI + ARKit + Metal starter for scanning indoor rooms into a colored, fused point cloud and exploring it from a virtual orbit camera.

## Included

- ARKit world tracking and scene-depth capture
- Depth back-projection into ARKit world coordinates
- Approximate RGB colorization from the captured YCbCr camera buffer
- Confidence filtering and keyframe-style frame selection
- 2 cm voxel fusion
- Metal point-cloud renderer with orbit, pinch zoom, and two-finger pan
- Frame-room, clear, pause/resume, and ASCII PLY export

## Requirements

- Recent Xcode
- Physical LiDAR-equipped iPhone Pro / Pro Max
- iOS version supported by your installed Xcode and device
- Camera permission

The simulator does not provide the same LiDAR capture behavior as a physical supported device.

## Add the source to Xcode

1. Create a new **iOS App** project named `RoomScanner`.
2. Choose SwiftUI and Swift.
3. Add all files in `RoomScanner/` to the app target. Ensure `Shaders.metal` is included in Compile Sources and is copied/compiled as a Metal source.
4. In the target's Info settings, add `Privacy - Camera Usage Description` (`NSCameraUsageDescription`) with a message such as: `Camera and depth data are used to reconstruct a 3D room.`
5. Set a deployment target compatible with the ARKit APIs available in your chosen Xcode SDK.
6. Run on a physical LiDAR-equipped iPhone Pro.

## Important prototype notes

This is a first-pass starter, not a production-validated scanner. Build and test it on the target Xcode/iOS version and correct any SDK-specific compiler issues before relying on it.

- The camera-image-to-depth mapping and YCbCr color conversion are approximate. Validate color registration against a known target and use ARKit's calibrated image mapping as needed.
- Voxel fusion averages points within cells; it is not TSDF fusion and does not create a watertight mesh.
- ARKit pose drift can cause doubled surfaces during long loops. The current version does not implement loop closure or global pose optimization.
- The in-memory voxel map is capped at 1.5 million voxels. It does not yet stream map chunks to disk.
- PLY export uses ASCII and can be slow for large clouds.
- The renderer currently rebuilds one GPU buffer from a full snapshot after updates. A production version should upload only changed spatial chunks.
- `ARWorldMap` persistence is not implemented; PLY saves geometry only.
- Scene depth availability is checked at runtime. Add a clear unsupported-device UI for shipping.
- For strict thread safety and performance, publish immutable chunk snapshots from the fusion queue and avoid repeatedly copying the entire map.

## Recommended next steps

1. Build and validate the basic capture pipeline.
2. Verify camera-axis conventions and RGB/depth alignment with a small test scene.
3. Add spatial chunk buffers and GPU-side point filtering.
4. Add session checkpointing and binary map persistence.
5. Add TSDF fusion and mesh extraction only after point-cloud scanning is stable.
