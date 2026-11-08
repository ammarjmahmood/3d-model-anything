# Parking survey capture

The fork opens into **Parking survey**, a separate ARKit session with no RoomPlan room completion, walls, furniture fitting, floor-plan bounds or room meshing. Existing indoor captures remain available under **Indoor room capture**. Requires iOS 17+ and LiDAR; intended first device: iPhone 16 Pro Max.

## Install on your Mac

```sh
git clone https://github.com/ammarjmahmood/3d-model-anything.git
cd 3d-model-anything/apps/house-capture
brew install xcodegen  # if not installed
xcodegen generate
open HouseCapture.xcodeproj
```

In Xcode select your Apple development team, change the bundle identifier to your own unique identifier, select your paired iPhone, and Run. Wireless installation uses Xcode's existing device pairing. Developer Mode alone does not pair a phone. You may need to pair by cable first. No paid API or World Labs key is needed to capture. Xcode generation is required after adding the new Swift file.

## Walk and export

1. Enter site, outdoor lot/garage, and level/aisle (for example BMW Markham / Ground / west aisle).
2. Start walking capture; allow camera and optional location access. Hold the phone steadily and walk slowly, looking obliquely toward curbs, vehicles, columns and other stable features, rather than only at featureless asphalt. Keep shared features in neighboring images.
3. Finish each short aisle/level segment. Segments stop automatically after two minutes to encourage bounded walks. Repeat with overlapping coverage and recognizable common features. Each segment has its **own** AR world; adjacent segments are not automatically registered.
4. Tap a saved segment to export ZIP through AirDrop or Files. Files → Parking Survey → ParkingSurveys also contains the original segment folders. Saved entries currently show their UUID. Keep the originals until the export has been checked.
5. Unzip on your Mac and prepare portable image batches:

```sh
python3 tools/parking-survey/prepare.py /path/to/segment /path/to/atlas-batches
```

The tool checks camera metadata, assets, raw depth sizes and completion status; copies unmodified sensor-orientation JPEGs into overlapping batches (16 images, 4 shared, minimum 1 second spacing); and emits `cameras.json` plus an LLM-readable `handoff.json`. This is a starting selection: inspect blur, overlap, moving vehicles/people and view coverage yourself. It does not score sharpness or reconstruct a point cloud. Time spacing alone cannot guarantee overlap. Use `--spacing 0.5` for more views.

## Data contract: parking-survey/1

This export intentionally does not masquerade as the indoor `house-capture/5` format. The existing room importer/viewer cannot consume these survey bundles yet.

- `manifest.json`: site, environment, level, state, timestamps, coordinate conventions, counts and explicit unaligned georeference status. Updated every 10 samples and at completion.
- `video.mov`: H.264 sensor-orientation RGB video, targeted up to 30 fps; no microphone audio. Writer backpressure drops frames and records a count. Actual frame rate/resolution depends on ARKit's selected camera format.
- `frames.jsonl`: video-frame poses and sampled-image metadata. ARKit camera-to-world matrices are column-major, metric, Y-up, camera looks along -Z. Camera intrinsics describe unrotated sensor pixels; quaternion is XYZW with `coordinateSystem: rub`. Each record identifies whether a video frame was actually written. Presentation time is `timestamp - videoOriginTimestamp`. Unix time is estimated using the device uptime at callback; it is not a hardware synchronization guarantee with an external robot.
- `rgb/NNNNNN.jpg`: full AR camera-frame JPEGs, up to 2/s during normal tracking. These are video-resolution reference images, not 48MP still photos. No rotation or crop is applied.
- `depth/NNNNNN.f32`: paired unsmoothed LiDAR depth, tightly row-packed Float32 little-endian metres. Dimensions are in the associated frame's depth record. No reliable return is not a measured surface: use confidence and finite/positive masks. Scale RGB intrinsics by depthWidth/rgbWidth and depthHeight/rgbHeight for depth unprojection. Device depth resolution is not hardcoded.
- `depth/NNNNNN.confidence.u8`: same-resolution raw UInt8 confidence (0 low, 1 medium, 2 high), when available.
- `locations.jsonl`: WGS84 latitude/longitude, altitude, original GPS timestamp and reported horizontal/vertical accuracy. Invalid horizontal fixes are excluded. Negative vertical accuracy means altitude is invalid. Location permission may be denied and GPS may be absent/stale inside a garage. GPS samples are a separate stream, not fabricated per-frame fixes.

Writes occur on a serial queue, append-only logs avoid growing in-memory frame collections, and capture stops on backgrounding, interruption or write failure. Thermal serious/critical state stops capture. Normal finishing finalizes the movie before export. A crash may leave a `recording` manifest and unfinalized movie; the preparation tool refuses these. RGB/depth and complete JSONL lines may still be recoverable manually. This is not a guarantee of crash-proof video storage. It does not yet record raw IMU, reconstructed meshes, surveyed control points, external LiDAR synchronization or high-accuracy heading.

## Atlas / World Labs

Official references (checked November 8, 2026):

- https://docs.atlas-beta.worldlabs.ai/using-video-footage
- https://docs.atlas-beta.worldlabs.ai/cameras-and-posed-images

The current Atlas beta image workflow takes selected still images; it does not accept direct video upload. Import a reviewed batch's JPEGs together in Viewfinder with **Reconstruct**, or upload them using your World Labs account and call `images2PosedRGBD` with image assets **without cameras**. The local preparation output is not itself an API request and performs no uploads.

`cameras.json` retains ARKit calibration for posed workflows. Its intrinsics/extrinsics follow the documented RUB, camera-to-world, XYZW conventions. Upload assets and supply their asset IDs in the relevant task's frame structure; a local file path is not an Atlas asset ID. Validate lens calibration, shared frame and exact task constraints before use. Do not combine independently captured segments as one posed scene without registration. Do not resize or rotate images without transforming intrinsics and paired depth. The current `.f32` files are not Atlas-ready depth EXRs.

Start with one well-covered aisle. Reconstruct and inspect it before attempting a whole property. Independent Atlas image-only reconstructions may recover different coordinate frames/scales. Automatic World Labs uploads, USD/Isaac import, metric mesh reconstruction and global stitching are not implemented in this first capture adaptation.

## Satellite alignment and robot simulation

GPS is retained for later geospatial work, but an accurate satellite alignment has **not** been calculated. Do not interpret GPS accuracy as a precision guarantee. To align metric geometry, collect common surveyed/visually matched control points (curb corners, posts, lane-marking corners), obtain appropriately licensed orthographic imagery with CRS/resolution/acquisition date, and solve and verify a coordinate transform. Satellite imagery cannot establish hidden garage levels; retain level labels and survey control there. Aerial and phone captures may show different parked vehicles.

Preserve raw evidence. Label generated fill separately from observed geometry. ARKit can drift over open lots; phone LiDAR cannot measure an entire lot from one position and outdoor returns may be unreliable. For robot training, validate scale, curb heights, ramps, lane widths, collision geometry and global alignment against surveyed or external LiDAR measurements. Generated splats alone are not collision meshes or certified ground truth. This capture app does not solve those downstream reconstruction and validation steps.

## Validation

```sh
python3 -m unittest discover -s tools/parking-survey -v
```

The Mac CI job builds an unsigned iOS Simulator target. Simulator compilation does not validate LiDAR behavior. Before relying on a field survey, use Xcode to build/run on the actual phone and test: camera denied, location denied, GPS unavailable, normal walk, tracking loss, interruption/backgrounding, video playback, export/reopen, changing levels, and multiple adjacent segments. Check depth/RGB projection against a known curb or post, timestamps against movie frames, and actual device storage/thermal load.
