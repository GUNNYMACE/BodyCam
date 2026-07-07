//
//  BodyCamRecorder.swift
//  BodyCam
//

import AVFoundation
import Foundation
import Observation
import Photos

@Observable
final class BodyCamRecorder: NSObject {
    private(set) var mode: BodyCamMode = .notInUse
    private(set) var statusMessage = "Ready"
    private(set) var errorMessage: String?
    private(set) var bufferedSegmentCount = 0
    private(set) var savedSegmentCount = 0
    private(set) var lastSavedBufferSegmentCount = 0

    @ObservationIgnored let session = AVCaptureSession()

    @ObservationIgnored private let configuration: BodyCamConfiguration
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "BodyCamRecorder.session")
    @ObservationIgnored private let fileManager = FileManager.default

    @ObservationIgnored private var isSessionConfigured = false
    @ObservationIgnored private var requestedMode: BodyCamMode = .notInUse
    @ObservationIgnored private var currentSegmentURL: URL?
    @ObservationIgnored private var activeRecordingDirectory: URL?
    @ObservationIgnored private var pendingModeAfterRecordingSave: BodyCamMode?
    @ObservationIgnored private var currentSegmentShouldSaveToRecording = false
    @ObservationIgnored private var shouldSaveBufferAfterCurrentSegment = false
    @ObservationIgnored private var shouldSaveRecordingAfterCurrentSegment = false

    init(configuration: BodyCamConfiguration = BodyCamConfiguration()) {
        self.configuration = configuration
        super.init()
    }

    func setMode(_ newMode: BodyCamMode) {
        switch newMode {
        case .notInUse:
            stopAll()
        case .buffering, .recording:
            startCapture(mode: newMode)
        }
    }

    func stopAll() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if requestedMode == .recording {
                finishActiveRecording(then: .notInUse)
                return
            }

            requestedMode = .notInUse
            activeRecordingDirectory = nil
            pendingModeAfterRecordingSave = nil

            if movieOutput.isRecording {
                movieOutput.stopRecording()
            } else {
                stopSessionIfNeeded()
            }

            publishMode(.notInUse, message: "Camera idle")
        }
    }

    func saveCurrentBuffer() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                try prepareStorageIfNeeded()
            } catch {
                publishError(error.localizedDescription)
                return
            }

            shouldSaveBufferAfterCurrentSegment = true
            publishStatus("Saving current buffer")

            if movieOutput.isRecording {
                movieOutput.stopRecording()
            } else {
                saveRollingBufferSnapshot()
                shouldSaveBufferAfterCurrentSegment = false
            }
        }
    }

    private func startCapture(mode newMode: BodyCamMode) {
        requestCaptureAccess { [weak self] granted in
            guard let self else { return }

            guard granted else {
                publishError("Camera and microphone access are required.")
                publishMode(.notInUse, message: "Permission needed")
                return
            }

            sessionQueue.async { [weak self] in
                guard let self else { return }

                do {
                    try configureSessionIfNeeded()
                    try prepareStorageIfNeeded()

                    if requestedMode == .recording && newMode != .recording {
                        finishActiveRecording(then: newMode)
                        return
                    }

                    let isStartingNewBuffer = requestedMode == .notInUse
                    if isStartingNewBuffer {
                        clearRollingBuffer()
                    }

                    requestedMode = newMode
                    if newMode == .recording, activeRecordingDirectory == nil {
                        activeRecordingDirectory = try makeRecordingDirectory()
                    }

                    if !session.isRunning {
                        session.startRunning()
                    }

                    if !movieOutput.isRecording {
                        try startNextSegment()
                    }

                    publishMode(newMode, message: newMode.statusText)
                } catch {
                    publishError(error.localizedDescription)
                    publishMode(.notInUse, message: "Capture failed")
                    stopSessionIfNeeded()
                }
            }
        }
    }

    private func configureSessionIfNeeded() throws {
        guard !isSessionConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw BodyCamRecorderError.missingCamera
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw BodyCamRecorderError.cannotAddCamera
        }
        session.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
        }

        guard session.canAddOutput(movieOutput) else {
            throw BodyCamRecorderError.cannotAddMovieOutput
        }
        session.addOutput(movieOutput)

        movieOutput.maxRecordedDuration = CMTime(
            seconds: Double(configuration.segmentDurationSeconds),
            preferredTimescale: 600
        )

        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .standard
        }

        isSessionConfigured = true
    }

    private func startNextSegment() throws {
        guard requestedMode != .notInUse else { return }
        try prepareStorageIfNeeded()

        let segmentURL = makeSegmentURL()
        currentSegmentURL = segmentURL
        currentSegmentShouldSaveToRecording = requestedMode == .recording
        movieOutput.startRecording(to: segmentURL, recordingDelegate: self)
    }

    private func finishSegment(at outputFileURL: URL, error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if let error {
                publishError(error.localizedDescription)
            } else {
                if currentSegmentShouldSaveToRecording {
                    copySegmentToActiveRecording(outputFileURL)
                }

                cleanupRollingBuffer()

                if shouldSaveBufferAfterCurrentSegment {
                    saveRollingBufferSnapshot()
                    shouldSaveBufferAfterCurrentSegment = false
                }

                if shouldSaveRecordingAfterCurrentSegment {
                    saveActiveRecording()
                    shouldSaveRecordingAfterCurrentSegment = false
                }

                publishSegmentCounts()
            }

            currentSegmentURL = nil
            currentSegmentShouldSaveToRecording = false

            guard requestedMode != .notInUse else {
                stopSessionIfNeeded()
                return
            }

            do {
                try startNextSegment()
                publishMode(requestedMode, message: requestedMode.statusText)
            } catch {
                publishError(error.localizedDescription)
                requestedMode = .notInUse
                publishMode(.notInUse, message: "Capture failed")
                stopSessionIfNeeded()
            }
        }
    }

    private func finishActiveRecording(then nextMode: BodyCamMode) {
        pendingModeAfterRecordingSave = nextMode
        shouldSaveRecordingAfterCurrentSegment = true
        requestedMode = nextMode
        publishMode(nextMode, message: "Saving recording")

        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            saveActiveRecording()
            shouldSaveRecordingAfterCurrentSegment = false
        }
    }

    private func stopSessionIfNeeded() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func requestCaptureAccess(completion: @escaping (Bool) -> Void) {
        requestAccess(for: .video) { videoGranted in
            guard videoGranted else {
                completion(false)
                return
            }

            self.requestAccess(for: .audio) { audioGranted in
                completion(audioGranted)
            }
        }
    }

    private func requestAccess(for mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func prepareStorageIfNeeded() throws {
        try fileManager.createDirectory(at: bufferDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: savedBuffersDirectory, withIntermediateDirectories: true)
    }

    private var bufferDirectory: URL {
        applicationSupportDirectory.appending(path: "RollingBuffer", directoryHint: .isDirectory)
    }

    private var recordingsDirectory: URL {
        applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    private var savedBuffersDirectory: URL {
        applicationSupportDirectory.appending(path: "SavedBuffers", directoryHint: .isDirectory)
    }

    private var applicationSupportDirectory: URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls[0].appending(path: "BodyCam", directoryHint: .isDirectory)
    }

    private func makeSegmentURL() -> URL {
        let filename = "segment-\(Self.timestampString()).mov"
        return bufferDirectory.appending(path: filename, directoryHint: .notDirectory)
    }

    private func makeRecordingDirectory() throws -> URL {
        let directory = recordingsDirectory.appending(path: "recording-\(Self.timestampString())", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func copySegmentToActiveRecording(_ segmentURL: URL) {
        guard let activeRecordingDirectory else { return }

        let destinationURL = activeRecordingDirectory.appending(path: segmentURL.lastPathComponent, directoryHint: .notDirectory)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: segmentURL, to: destinationURL)
        } catch {
            publishError("Could not save recording segment: \(error.localizedDescription)")
        }
    }

    private func saveActiveRecording() {
        guard let recordingDirectory = activeRecordingDirectory else {
            publishError("No active recording was available to save.")
            return
        }

        let segmentURLs = sortedSegmentURLs(in: recordingDirectory)
        guard !segmentURLs.isEmpty else {
            publishError("No recorded footage was available to save.")
            activeRecordingDirectory = nil
            publishSegmentCounts()
            return
        }

        publishStatus("Stitching recording")
        stitchAndSaveRecordingToPhotoLibrary(segmentURLs, outputDirectory: recordingDirectory)
        activeRecordingDirectory = nil
        pendingModeAfterRecordingSave = nil
        publishSegmentCounts()
    }

    private func saveRollingBufferSnapshot() {
        let segmentURLs = sortedBufferSegmentURLs()
        guard !segmentURLs.isEmpty else {
            publishStatus("No buffered footage to save yet")
            publishLastSavedBufferSegmentCount(0)
            return
        }

        do {
            let destinationDirectory = savedBuffersDirectory.appending(
                path: "buffer-\(Self.timestampString())",
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            var copiedSegmentURLs: [URL] = []
            for segmentURL in segmentURLs {
                let destinationURL = destinationDirectory.appending(
                    path: segmentURL.lastPathComponent,
                    directoryHint: .notDirectory
                )
                try fileManager.copyItem(at: segmentURL, to: destinationURL)
                copiedSegmentURLs.append(destinationURL)
            }

            publishStatus("Stitching \(copiedSegmentURLs.count) buffer segment\(copiedSegmentURLs.count == 1 ? "" : "s")")
            publishLastSavedBufferSegmentCount(copiedSegmentURLs.count)
            stitchAndSaveBufferToPhotoLibrary(copiedSegmentURLs, outputDirectory: destinationDirectory)
        } catch {
            publishError("Could not save buffer: \(error.localizedDescription)")
        }
    }

    private func stitchAndSaveBufferToPhotoLibrary(_ segmentURLs: [URL], outputDirectory: URL) {
        stitchAndSaveMovieToPhotoLibrary(
            segmentURLs,
            outputDirectory: outputDirectory,
            outputFilenamePrefix: "stitched-buffer",
            stitchErrorPrefix: "Could not stitch buffer",
            successMessage: "Saved stitched buffer clip to Photos",
            updatesLastSavedBufferCount: true
        )
    }

    private func stitchAndSaveRecordingToPhotoLibrary(_ segmentURLs: [URL], outputDirectory: URL) {
        stitchAndSaveMovieToPhotoLibrary(
            segmentURLs,
            outputDirectory: outputDirectory,
            outputFilenamePrefix: "stitched-recording",
            stitchErrorPrefix: "Could not stitch recording",
            successMessage: "Saved recording to Photos",
            updatesLastSavedBufferCount: false
        )
    }

    private func stitchAndSaveMovieToPhotoLibrary(
        _ segmentURLs: [URL],
        outputDirectory: URL,
        outputFilenamePrefix: String,
        stitchErrorPrefix: String,
        successMessage: String,
        updatesLastSavedBufferCount: Bool
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let outputURL = outputDirectory.appending(
                    path: "\(outputFilenamePrefix)-\(UUID().uuidString).mov",
                    directoryHint: .notDirectory
                )
                let stitchedURL = try await stitchSegments(segmentURLs, outputURL: outputURL)
                await MainActor.run {
                    self.saveMovieToPhotoLibrary(
                        stitchedURL,
                        segmentCount: segmentURLs.count,
                        successMessage: successMessage,
                        updatesLastSavedBufferCount: updatesLastSavedBufferCount
                    )
                }
            } catch {
                await MainActor.run {
                    self.publishError("\(stitchErrorPrefix): \(error.localizedDescription)")
                }
            }
        }
    }

    private func saveMovieToPhotoLibrary(
        _ movieURL: URL,
        segmentCount: Int,
        successMessage: String,
        updatesLastSavedBufferCount: Bool
    ) {
        requestPhotoLibraryAddAccess { [weak self] granted in
            guard let self else { return }

            guard granted else {
                publishError("Photo library add access is required to save buffered footage to Photos.")
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: movieURL, options: nil)
            } completionHandler: { [weak self] success, error in
                guard let self else { return }

                if success {
                    publishStatus(successMessage)
                    if updatesLastSavedBufferCount {
                        publishLastSavedBufferSegmentCount(segmentCount)
                    }
                } else {
                    publishError("Could not save movie to Photos: \(error?.localizedDescription ?? "Unknown error")")
                }
            }
        }
    }

    private func stitchSegments(_ segmentURLs: [URL], outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()

        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw BodyCamRecorderError.cannotCreateCompositionTrack
        }

        let audioCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertionTime = CMTime.zero
        var hasAppliedVideoOrientation = false

        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                continue
            }

            if !hasAppliedVideoOrientation {
                videoCompositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
                hasAppliedVideoOrientation = true
            }

            try videoCompositionTrack.insertTimeRange(timeRange, of: videoTrack, at: insertionTime)

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try audioCompositionTrack?.insertTimeRange(timeRange, of: audioTrack, at: insertionTime)
            }

            insertionTime = insertionTime + duration
        }

        guard insertionTime > .zero else {
            throw BodyCamRecorderError.emptyBuffer
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw BodyCamRecorderError.cannotCreateExportSession
        }

        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    private func requestPhotoLibraryAddAccess(completion: @escaping (Bool) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                completion(status == .authorized || status == .limited)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func clearRollingBuffer() {
        for segmentURL in sortedBufferSegmentURLs() {
            try? fileManager.removeItem(at: segmentURL)
        }
        publishSegmentCounts()
    }

    private func cleanupRollingBuffer() {
        let segmentURLs = sortedBufferSegmentURLs()
        let allowedCount = configuration.bufferedSegmentCount
        guard segmentURLs.count > allowedCount else { return }

        for url in segmentURLs.prefix(segmentURLs.count - allowedCount) {
            if url != currentSegmentURL {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func publishSegmentCounts() {
        let bufferCount = sortedBufferSegmentURLs().count
        let savedCount = activeRecordingSegmentCount()

        DispatchQueue.main.async { [weak self] in
            self?.bufferedSegmentCount = bufferCount
            self?.savedSegmentCount = savedCount
        }
    }

    private func sortedBufferSegmentURLs() -> [URL] {
        sortedSegmentURLs(in: bufferDirectory)
    }

    private func sortedSegmentURLs(in directory: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { lhs, rhs in
                creationDate(for: lhs) < creationDate(for: rhs)
            }
    }

    private func activeRecordingSegmentCount() -> Int {
        guard let activeRecordingDirectory else {
            return 0
        }

        return sortedSegmentURLs(in: activeRecordingDirectory).count
    }

    private func creationDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate ?? .distantPast
    }

    private func publishMode(_ newMode: BodyCamMode, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.mode = newMode
            self?.statusMessage = message
        }
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = message
        }
    }

    private func publishLastSavedBufferSegmentCount(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.lastSavedBufferSegmentCount = count
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

extension BodyCamRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        finishSegment(at: outputFileURL, error: error)
    }
}

private enum BodyCamRecorderError: LocalizedError {
    case missingCamera
    case cannotAddCamera
    case cannotAddMovieOutput
    case cannotCreateCompositionTrack
    case cannotCreateExportSession
    case emptyBuffer

    var errorDescription: String? {
        switch self {
        case .missingCamera:
            "No camera is available on this device."
        case .cannotAddCamera:
            "The camera could not be added to the capture session."
        case .cannotAddMovieOutput:
            "Movie recording could not be added to the capture session."
        case .cannotCreateCompositionTrack:
            "The buffered footage could not be prepared for stitching."
        case .cannotCreateExportSession:
            "The stitched buffer export could not be created."
        case .emptyBuffer:
            "No usable buffered video was available to stitch."
        }
    }
}
