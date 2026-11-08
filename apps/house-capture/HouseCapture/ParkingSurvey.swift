import SwiftUI
import ARKit
import AVFoundation
import CoreLocation
import CoreImage
import UniformTypeIdentifiers

/// RoomPlan deliberately never participates in this session. Each walk is an independent
/// metric coordinate frame; GPS is evidence for alignment, never a substitute for it.
final class ParkingSurveyRecorder: NSObject, ObservableObject, ARSessionDelegate, CLLocationManagerDelegate {
  @Published var recording = false
  @Published var busy = false
  @Published var status = "Ready for a short overlapping walk"
  @Published var error: String?
  @Published var samples = 0
  @Published var folder: URL?
  let session = ARSession()
  private let queue = DispatchQueue(label: "parking-survey.writer", qos: .userInitiated)
  private let location = CLLocationManager()
  private let context = CIContext()
  private var active = false
  private var finishing = false
  private var destination: URL?
  private var frames: FileHandle?
  private var locations: FileHandle?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var firstTime: Double?
  private var lastSample = -Double.infinity
  private var lastVideo = -Double.infinity
  private var count = 0
  private var videoCount = 0
  private var droppedVideo = 0
  private var started = ""
  private var site = ""
  private var kind = ""
  private var level = ""

  override init() {
    super.init()
    session.delegate = self
    session.delegateQueue = queue
    location.delegate = self
    location.desiredAccuracy = kCLLocationAccuracyBest
    location.distanceFilter = 1
  }

  static var root: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ParkingSurveys", isDirectory: true)
  }

  func start(site: String, kind: String, level: String) {
    guard !busy, !recording else { return }
    guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
      error = "This capture requires a LiDAR-equipped iPhone or iPad."
      return
    }
    busy = true
    Task { @MainActor in
      let allowed = await AVCaptureDevice.requestAccess(for: .video)
      guard allowed else { error = "Allow camera access in Settings."; busy = false; return }
      guard UIApplication.shared.applicationState == .active else { busy = false; return }
      self.site = site; self.kind = kind; self.level = level
      UIApplication.shared.isIdleTimerDisabled = true
      location.requestWhenInUseAuthorization()
      location.startUpdatingLocation()
      queue.async {
        self.finishing = false
        do {
          let url = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: url.appendingPathComponent("rgb"), withIntermediateDirectories: true)
          try FileManager.default.createDirectory(at: url.appendingPathComponent("depth"), withIntermediateDirectories: true)
          self.destination = url
          self.started = ISO8601DateFormatter().string(from: Date())
          self.count = 0; self.videoCount = 0; self.droppedVideo = 0
          self.firstTime = nil; self.lastSample = -.infinity; self.lastVideo = -.infinity
          self.writer = nil; self.input = nil; self.adaptor = nil
          self.frames = try self.openLog(url.appendingPathComponent("frames.jsonl"))
          self.locations = try self.openLog(url.appendingPathComponent("locations.jsonl"))
          try self.manifest(state: "recording")
          self.active = true
          let config = ARWorldTrackingConfiguration()
          config.worldAlignment = .gravity
          config.frameSemantics = [.sceneDepth]
          // No room bounds, plane flattening, semantic furniture, or accumulated mesh.
          self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
          DispatchQueue.main.async {
            self.folder = url; self.samples = 0; self.busy = false; self.recording = true
            self.status = "Walk slowly; overlap views. Finish each aisle or garage level separately."
          }
        } catch { self.fail(error) }
      }
    }
  }

  func stop() {
    guard recording, !busy else { return }
    busy = true
    location.stopUpdatingLocation()
    queue.async { self.finish(state: "complete") }
  }

  private func openLog(_ url: URL) throws -> FileHandle {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try FileHandle(forWritingTo: url)
  }

  private func line(_ value: [String: Any], to handle: FileHandle?) throws {
    guard let handle else { throw CocoaError(.fileWriteUnknown) }
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    try handle.write(contentsOf: data)
  }

  private func manifest(state: String) throws {
    guard let destination else { return }
    let value: [String: Any] = [
      "schema": "parking-survey/1", "state": state, "site": site,
      "environment": kind, "level": level, "startedAt": started,
      "updatedAt": ISO8601DateFormatter().string(from: Date()),
      "device": UIDevice.current.model, "systemVersion": UIDevice.current.systemVersion,
      "samples": count, "videoFrames": videoCount, "droppedVideoFrames": droppedVideo,
      "coordinates": ["units": "metres", "world": "ARKit gravity-aligned Y-up; independent per segment",
                      "camera": "right-up-back; looks along -Z", "transform": "camera-to-world; column-major 4x4",
                      "image": "unrotated sensor pixels; top-left origin; intrinsics in pixels"],
      "depthEncoding": "row-packed little-endian Float32 metres; confidence UInt8 0/1/2; dimensions per frame",
      "time": "ARFrame monotonic seconds; unixTime estimated at callback; GPS has own unix timestamp",
      "video": "video.mov; unrotated sensor pixels; presentation time = AR timestamp - videoOriginTimestamp",
      "georeference": ["status": "unaligned", "source": "WGS84 GPS samples with reported accuracy",
                       "satelliteAlignment": "requires surveyed or manually matched control points; not yet applied"],
      "groundTruth": "Sensor evidence only; ARKit drifts. Generated Atlas content must be labelled synthetic."
    ]
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard active, let destination else { return }
    autoreleasepool {
      do {
        if let firstTime, frame.timestamp - firstTime >= 120 {
          finish(state: "complete")
          return
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
          DispatchQueue.main.async { self.error = "Phone is hot. Let it cool before the next segment." }
          finish(state: "interrupted")
          return
        }
        if firstTime == nil { try beginVideo(frame, at: destination) }
        var appended = false
        if frame.timestamp - lastVideo >= 1.0 / 30.0 {
          if let input, input.isReadyForMoreMediaData, let adaptor, let firstTime {
            guard adaptor.append(frame.capturedImage, withPresentationTime: CMTime(seconds: frame.timestamp - firstTime, preferredTimescale: 60000)) else {
              throw writer?.error ?? CocoaError(.fileWriteUnknown)
            }
            videoCount += 1; lastVideo = frame.timestamp; appended = true
          } else { droppedVideo += 1 }
        }
        let normal: Bool
        let tracking: String
        switch frame.camera.trackingState {
        case .normal: normal = true; tracking = "normal"
        case .notAvailable: normal = false; tracking = "unavailable"
        case .limited(let reason): normal = false; tracking = "limited: \(reason)"
        }
        // Keep poses for every written video frame and sampled RGB-D; no unbounded arrays.
        let sample = normal && frame.timestamp - lastSample >= 0.5
        guard appended || sample else { return }
        let k = frame.camera.intrinsics
        let t = frame.camera.transform
        let q = simd_quatf(t).vector
        var record: [String: Any] = [
          "timestamp": frame.timestamp, "unixTime": Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - frame.timestamp),
          "videoOriginTimestamp": firstTime ?? frame.timestamp, "videoFrameWritten": appended,
          "tracking": tracking, "width": CVPixelBufferGetWidth(frame.capturedImage), "height": CVPixelBufferGetHeight(frame.capturedImage),
          "transform": (0..<4).flatMap { c in (0..<4).map { r in t[c][r] } },
          "camera": ["intrinsics": ["fx": k[0][0], "fy": k[1][1], "cx": k[2][0], "cy": k[2][1],
                                    "width": CVPixelBufferGetWidth(frame.capturedImage), "height": CVPixelBufferGetHeight(frame.capturedImage)],
                     "extrinsics": ["position": [t[3][0], t[3][1], t[3][2]], "quaternion": [q.x,q.y,q.z,q.w], "coordinateSystem": "rub"]],
          "exposureDuration": frame.camera.exposureDuration, "exposureOffset": frame.camera.exposureOffset
        ]
        if sample {
          let stem = String(format: "%06d", count)
          let rgb = "rgb/\(stem).jpg"
          try context.writeJPEGRepresentation(of: CIImage(cvPixelBuffer: frame.capturedImage), to: destination.appendingPathComponent(rgb), colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
          record["rgb"] = rgb
          if let depth = frame.sceneDepth {
            let file = "depth/\(stem).f32"
            try packed(depth.depthMap, bytesPerPixel: 4).write(to: destination.appendingPathComponent(file))
            var info: [String: Any] = ["file": file, "width": CVPixelBufferGetWidth(depth.depthMap), "height": CVPixelBufferGetHeight(depth.depthMap)]
            if let confidence = depth.confidenceMap {
              let conf = "depth/\(stem).confidence.u8"
              try packed(confidence, bytesPerPixel: 1).write(to: destination.appendingPathComponent(conf))
              info["confidence"] = conf
            }
            record["depth"] = info
          }
          count += 1; lastSample = frame.timestamp
        }
        try line(record, to: frames)
        if sample && count % 10 == 0 { try frames?.synchronize(); try locations?.synchronize(); try manifest(state: "recording") }
        if sample || !normal {
          let total = count
          DispatchQueue.main.async {
            self.samples = total
            self.status = normal ? "\(total) RGB-D samples · finish this segment before a long turn or level change" : "Tracking \(tracking). Slow down and return to recognizable features."
          }
        }
      } catch { fail(error) }
    }
  }

  private func beginVideo(_ frame: ARFrame, at url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url.appendingPathComponent("video.mov"), fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: CVPixelBufferGetWidth(frame.capturedImage),
      AVVideoHeightKey: CVPixelBufferGetHeight(frame.capturedImage),
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
    ])
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    self.writer = writer; self.input = input; self.adaptor = adaptor; firstTime = frame.timestamp
  }

  private func packed(_ buffer: CVPixelBuffer, bytesPerPixel: Int) throws -> Data {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw CocoaError(.fileReadUnknown) }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.fileReadUnknown) }
    let row = CVPixelBufferGetWidth(buffer) * bytesPerPixel
    var data = Data(capacity: row * CVPixelBufferGetHeight(buffer))
    for y in 0..<CVPixelBufferGetHeight(buffer) {
      data.append(base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self), count: row)
    }
    return data
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations values: [CLLocation]) {
    queue.async {
      guard self.active else { return }
      do {
        for value in values where value.horizontalAccuracy >= 0 {
          try self.line(["unixTime": value.timestamp.timeIntervalSince1970, "latitude": value.coordinate.latitude,
                         "longitude": value.coordinate.longitude, "altitude": value.altitude,
                         "horizontalAccuracy": value.horizontalAccuracy, "verticalAccuracy": value.verticalAccuracy], to: self.locations)
        }
      } catch { self.fail(error) }
    }
  }

  func session(_ session: ARSession, didFailWithError error: Error) { fail(error) }
  func sessionWasInterrupted(_ session: ARSession) {
    queue.async { if self.active { self.finish(state: "interrupted") } }
  }

  private func fail(_ error: Error) {
    let message = error.localizedDescription
    DispatchQueue.main.async { self.error = message }
    finish(state: "failed")
  }

  private func finish(state: String) {
    guard !finishing else { return }
    finishing = true
    active = false; session.pause()
    do { try frames?.synchronize(); try locations?.synchronize(); try frames?.close(); try locations?.close() }
    catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
    frames = nil; locations = nil
    let complete: (String) -> Void = { finalState in
      do { try self.manifest(state: finalState) }
      catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
      self.writer = nil; self.input = nil; self.adaptor = nil
      DispatchQueue.main.async {
        self.location.stopUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = false
        self.recording = false; self.busy = false
        self.status = "Saved \(self.count) samples (\(finalState)). Files → ParkingSurveys."
      }
    }
    if let writer, writer.status == .writing {
      input?.markAsFinished()
      writer.finishWriting { self.queue.async {
        if let error = writer.error { DispatchQueue.main.async { self.error = error.localizedDescription } }
        complete(writer.status == .completed ? state : "failed")
      } }
    } else { complete(state == "complete" ? "failed" : state) }
  }
}

private struct ParkingCamera: UIViewRepresentable {
  let session: ARSession
  func makeUIView(context: Context) -> ARSCNView {
    let view = ARSCNView(frame: .zero)
    view.session = session
    view.automaticallyUpdatesLighting = false
    return view
  }
  func updateUIView(_ view: ARSCNView, context: Context) {}
}

struct ParkingSurveyScreen: View {
  @StateObject private var recorder = ParkingSurveyRecorder()
  @State private var site = ""
  @State private var kind = "Outdoor parking lot"
  @State private var level = "Ground"
  @State private var saved: [URL] = []
  @State private var archive: URL?
  @State private var exporting = false
  @Environment(\.scenePhase) private var phase
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Parking survey").font(.largeTitle.bold())
          Text("Walk an aisle. Save a segment. Repeat with overlapping views.")
          TextField("Site — e.g. BMW Markham", text: $site).textFieldStyle(.roundedBorder)
            .disabled(recorder.recording || recorder.busy)
          Picker("Environment", selection: $kind) {
            Text("Outdoor lot").tag("Outdoor parking lot")
            Text("Garage").tag("Parking garage")
          }.pickerStyle(.segmented).disabled(recorder.recording || recorder.busy)
          TextField("Level / aisle", text: $level).textFieldStyle(.roundedBorder).disabled(recorder.recording || recorder.busy)
          if recorder.recording {
            ParkingCamera(session: recorder.session).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 16))
          }
          Text(recorder.status).font(.callout).accessibilityAddTraits(.updatesFrequently)
          if let error = recorder.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
          Button(recorder.recording ? "Finish segment" : "Start walking capture") {
            if recorder.recording { recorder.stop() }
            else { recorder.start(site: site, kind: kind, level: level) }
          }.buttonStyle(.borderedProminent).controlSize(.large).disabled(recorder.busy || exporting)
          Text("RGB video + photos + LiDAR depth + poses + GPS. GPS may be unavailable in garages. Stay near curbs, posts and parked vehicles to collect depth; distant asphalt and sky may have no reliable depth. Revisit recognizable features and overlap adjacent segments.")
            .font(.footnote).foregroundStyle(.secondary)
          Divider()
          Text("Saved segments").font(.headline)
          ForEach(saved, id: \.path) { url in
            Button { share(url) } label: {
              Label(url.lastPathComponent, systemImage: "square.and.arrow.up").font(.caption).lineLimit(1)
            }.disabled(recorder.recording || recorder.busy || exporting)
          }
          NavigationLink("Indoor room capture") { HomeView() }.disabled(recorder.recording || recorder.busy)
        }.padding()
      }
      .onAppear(perform: reload)
      .onChange(of: recorder.recording) { _, value in if !value { reload() } }
      .onChange(of: phase) { _, value in if value != .active { recorder.stop() } }
      .sheet(item: $archive) { ShareSheet(items: [$0]) }
    }
  }
  private func reload() {
    saved = ((try? FileManager.default.contentsOfDirectory(at: ParkingSurveyRecorder.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
  private func share(_ url: URL) {
    exporting = true
    Task {
      do { archive = try await Task.detached(priority: .userInitiated) { try FolderZipper.zip(url, name: "parking-survey-\(url.lastPathComponent)") }.value }
      catch { recorder.error = error.localizedDescription }
      exporting = false
    }
  }
}
