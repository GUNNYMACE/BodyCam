//
//  BodyCamMode.swift
//  BodyCam
//

import SwiftUI

enum BodyCamMode: String, CaseIterable, Identifiable {
    case notInUse = "Not in Use"
    case buffering = "Buffering"
    case recording = "Recording"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .notInUse:
            "pause.circle"
        case .buffering:
            "arrow.triangle.2.circlepath.camera"
        case .recording:
            "record.circle"
        }
    }

    var tint: Color {
        switch self {
        case .notInUse:
            .secondary
        case .buffering:
            .blue
        case .recording:
            .red
        }
    }

    var statusText: String {
        switch self {
        case .notInUse:
            "Camera idle"
        case .buffering:
            "Rolling buffer active"
        case .recording:
            "Recording and buffering"
        }
    }

    var storagePolicy: String {
        switch self {
        case .notInUse:
            "No camera capture or file writing."
        case .buffering:
            "Writes 5 second segments and deletes old footage after the buffer window."
        case .recording:
            "Writes 5 second segments to the buffer and keeps a full saved copy."
        }
    }
}

struct BodyCamConfiguration {
    let segmentDurationSeconds = 5
    let rollingBufferSeconds = 120

    var bufferedSegmentCount: Int {
        rollingBufferSeconds / segmentDurationSeconds
    }
}
