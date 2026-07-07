//
//  ContentView.swift
//  BodyCam
//
//  Created by Mason Likens on 7/7/26.
//

import SwiftUI

struct ContentView: View {
    @State private var recorder = BodyCamRecorder()
    @State private var telemetry = BodyCamTelemetry()
    @State private var showSettings = false
    @State private var showMetadata = true
    @State private var metadataStyle: MetadataStyle = .stacked
    @State private var outerCircleRotationDegrees = 90.0
    @State private var outerCircleDragDegrees = 0.0

    private let configuration = BodyCamConfiguration()

    var body: some View {
        ZStack {
            cameraSurface
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: advanceMode)

            VStack(spacing: 0) {
                topOverlay

                Spacer(minLength: 24)

                bottomOverlay
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .background(.black)
        .task {
            telemetry.start()
            await runClock()
        }
        .sheet(isPresented: $showSettings) {
            settingsView
        }
    }

    private var cameraSurface: some View {
        ZStack {
            CameraPreview(session: recorder.session)
                .overlay(.black.opacity(recorder.mode == .notInUse ? 0.48 : 0))

            if recorder.mode == .notInUse {
                Image(systemName: "video.slash")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
            }

            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private var topOverlay: some View {
        HStack(alignment: .top, spacing: 12) {
            if showMetadata {
                metadataBox
                    .frame(maxWidth: metadataStyle == .compact ? .infinity : 190, alignment: .leading)
            }

            Spacer(minLength: 8)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
            .accessibilityLabel("Settings")
        }
    }

    private var metadataBox: some View {
        VStack(alignment: .leading, spacing: metadataStyle == .compact ? 2 : 5) {
            Text("BodyCam")
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(recorder.mode.rawValue)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(currentModeTextColor)
                .lineLimit(1)

            Text(recorder.statusMessage)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if metadataStyle == .compact {
                Text("\(timeText) - \(dateText) - \(timeZoneText)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("Lat: \(latitudeText)   Long: \(longitudeText)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text(timeText)
                Text("\(dateText) / \(timeZoneText)")
                Text("Lat: \(latitudeText)")
                Text("Long: \(longitudeText)")
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private var bottomOverlay: some View {
        HStack(alignment: .bottom, spacing: 10) {
            quickButtons

            Spacer(minLength: 6)

            actionDial
        }
    }

    private var quickButtons: some View {
        HStack(spacing: 7) {
            ForEach(1...5, id: \.self) { index in
                Button {
                    handleQuickAction(index)
                } label: {
                    Text("B\(index)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.34), lineWidth: 1.2))
                .accessibilityLabel("Quick action \(index)")
            }
        }
    }

    private var actionDial: some View {
        ZStack(alignment: .center) {
            GlassEffectContainer(spacing: 10) {
                ZStack(alignment: .center) {
                    outerRotatingCircle
                        .rotationEffect(.degrees(outerCircleRotationDegrees + outerCircleDragDegrees))
                        .animation(.snappy(duration: 0.24), value: outerCircleRotationDegrees)

                    selectedEdgeLight

                    Circle()
                        .fill(.white.opacity(0.08))
                        .glassEffect(.regular.tint(.gray.opacity(0.2)), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.58), lineWidth: 1.4))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        .frame(width: 76, height: 76)
                        .allowsHitTesting(false)
                }
                .frame(width: 156, height: 156)
                .padding(28)
                .contentShape(Circle())
                .gesture(outerCircleRotationGesture)
                .accessibilityHidden(true)
                .padding(-28)
            }

            actionButton
        }
    }

    private var actionButton: some View {
        Button {
            recorder.saveCurrentBuffer()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.001))

                actionLabel
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .zIndex(100)
        .accessibilityLabel("Save buffer")
    }

    private var actionLabel: some View {
        Text("ACTION")
            .font(.system(size: 10, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .foregroundStyle(.white.opacity(0.96))
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
            .frame(width: 68, height: 14)
            .zIndex(100)
            .compositingGroup()
    }

    private var selectedEdgeLight: some View {
        Capsule()
            .fill(selectedCircleGlowColor.opacity(0.42))
            .frame(width: 58, height: 14)
            .blur(radius: 6)
            .rotationEffect(.degrees(-45))
            .offset(x: -42, y: -42)
            .allowsHitTesting(false)
    }

    private var outerRotatingCircle: some View {
        ZStack(alignment: .center) {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(selectedCircleGlowColor.opacity(0.1)))
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.46), lineWidth: 1.2)
                )
                .overlay(
                    Circle()
                        .stroke(selectedCircleGlowColor.opacity(0.58), lineWidth: 1.8)
                        .blur(radius: 0.4)
                )
                .shadow(color: selectedCircleGlowColor.opacity(0.34), radius: 14, y: 3)
                .frame(width: 156, height: 156)

            Rectangle()
                .fill(.white.opacity(0.62))
                .frame(width: 132, height: 1.4)
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)

            Rectangle()
                .fill(.white.opacity(0.62))
                .frame(width: 1.4, height: 132)
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)

            selectorText("RECORDING", rotation: .degrees(45))
                .offset(x: 39, y: -39)

            selectorText("BUFFERING", rotation: .degrees(-45))
                .offset(x: -39, y: -39)

            selectorText("OFF", rotation: .degrees(225))
                .offset(x: -39, y: 39)
        }
        .frame(width: 156, height: 156)
    }

    private func selectorText(_ title: String, rotation: Angle) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .foregroundStyle(.white.opacity(0.96))
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
            .frame(width: 68, height: 14)
            .rotationEffect(rotation)
    }

    private var selectedCircleMode: BodyCamMode {
        selectedMode(forRotation: outerCircleRotationDegrees + outerCircleDragDegrees)
    }

    private func selectedMode(forRotation rotationDegrees: Double) -> BodyCamMode {
        let topLeftAngle = -135.0
        let candidates: [(mode: BodyCamMode, angle: Double)] = [
            (.recording, -45),
            (.buffering, -135),
            (.notInUse, 135)
        ]

        return candidates.min { lhs, rhs in
            angularDistance(lhs.angle + rotationDegrees, topLeftAngle) < angularDistance(rhs.angle + rotationDegrees, topLeftAngle)
        }?.mode ?? .buffering
    }

    private var selectedCircleGlowColor: Color {
        selectedCircleMode == .notInUse ? .gray : selectedCircleMode.tint
    }

    private var selectorHitSize: CGFloat {
        212
    }

    private var outerCircleRotationGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard canStartOuterCircleRotation(at: value.startLocation, in: selectorHitSize) else {
                    outerCircleDragDegrees = 0
                    return
                }

                let dragDegrees = angleDelta(from: value.startLocation, to: value.location, in: selectorHitSize)
                outerCircleDragDegrees = clampedDragDegrees(dragDegrees)
            }
            .onEnded { value in
                guard canStartOuterCircleRotation(at: value.startLocation, in: selectorHitSize) else {
                    outerCircleDragDegrees = 0
                    return
                }

                let dragDegrees = clampedDragDegrees(angleDelta(from: value.startLocation, to: value.location, in: selectorHitSize))
                let momentumDegrees = dampedMomentumDegrees(for: value, actualDragDegrees: dragDegrees)
                let finalRotation = clampedSelectorRotation(outerCircleRotationDegrees + dragDegrees + momentumDegrees)

                let snappedRotation = snappedAllowedRotation(finalRotation)

                outerCircleDragDegrees = 0
                outerCircleRotationDegrees = snappedRotation
                recorder.setMode(selectedMode(forRotation: snappedRotation))
            }
    }

    private func canStartOuterCircleRotation(at point: CGPoint, in size: CGFloat) -> Bool {
        let center = CGPoint(x: size / 2, y: size / 2)
        let distance = hypot(point.x - center.x, point.y - center.y)
        let visibleOuterRadius = 78.0
        let centerButtonRadius = 38.0

        guard point.y <= center.y + visibleOuterRadius else {
            return false
        }

        return distance > centerButtonRadius
    }

    private func angleDelta(from startLocation: CGPoint, to location: CGPoint, in size: CGFloat) -> Double {
        let center = CGPoint(x: size / 2, y: size / 2)
        let startAngle = touchAngle(for: startLocation, center: center)
        let currentAngle = touchAngle(for: location, center: center)
        return normalizedSignedDegrees(currentAngle - startAngle)
    }

    private func touchAngle(for point: CGPoint, center: CGPoint) -> Double {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }

    private func dampedMomentumDegrees(for value: DragGesture.Value, actualDragDegrees: Double) -> Double {
        let predictedDragDegrees = angleDelta(from: value.startLocation, to: value.predictedEndLocation, in: selectorHitSize)
        let rawMomentum = normalizedSignedDegrees(predictedDragDegrees - actualDragDegrees)
        return min(max(rawMomentum * 0.35, -34), 34)
    }

    private func clampedDragDegrees(_ dragDegrees: Double) -> Double {
        clampedSelectorRotation(outerCircleRotationDegrees + dragDegrees) - outerCircleRotationDegrees
    }

    private func clampedSelectorRotation(_ degrees: Double) -> Double {
        min(max(degrees, -90), 90)
    }

    private func snappedAllowedRotation(_ degrees: Double) -> Double {
        let allowedRotations = [-90.0, 0.0, 90.0]
        return allowedRotations.min { lhs, rhs in
            abs(lhs - degrees) < abs(rhs - degrees)
        } ?? 0
    }


    private func angularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(normalizedSignedDegrees(lhs - rhs))
    }

    private func normalizedSignedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 {
            value -= 360
        } else if value < -180 {
            value += 360
        }
        return value
    }


    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Overlay") {
                    Toggle("Show info box", isOn: $showMetadata)
                    Picker("Info style", selection: $metadataStyle) {
                        ForEach(MetadataStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }

                Section("Capture") {
                    LabeledContent("Mode", value: recorder.mode.rawValue)
                    LabeledContent("Segment size", value: "\(configuration.segmentDurationSeconds) seconds")
                    LabeledContent("Rolling buffer", value: "\(configuration.rollingBufferSeconds) seconds")
                    LabeledContent("Location", value: telemetry.locationStatusMessage)
                }

                if let errorMessage = recorder.errorMessage {
                    Section("Last Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showSettings = false
                    }
                }
            }
        }
    }


    private var currentModeTextColor: Color {
        recorder.mode == .notInUse ? .white.opacity(0.72) : recorder.mode.tint
    }

    private var timeText: String {
        telemetry.currentDate.formatted(date: .omitted, time: .standard)
    }

    private var dateText: String {
        telemetry.currentDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year())
    }

    private var timeZoneText: String {
        TimeZone.current.abbreviation() ?? "Local"
    }

    private var latitudeText: String {
        telemetry.coordinate?.latitude.formatted(.number.precision(.fractionLength(6))) ?? "--"
    }

    private var longitudeText: String {
        telemetry.coordinate?.longitude.formatted(.number.precision(.fractionLength(6))) ?? "--"
    }

    private func primaryAction() {
        switch recorder.mode {
        case .notInUse:
            recorder.setMode(.buffering)
        case .buffering:
            recorder.saveCurrentBuffer()
        case .recording:
            recorder.setMode(.buffering)
        }
    }

    private func advanceMode() {
        switch recorder.mode {
        case .notInUse:
            recorder.setMode(.buffering)
        case .buffering:
            recorder.setMode(.recording)
        case .recording:
            recorder.setMode(.notInUse)
        }
    }

    private func handleQuickAction(_ index: Int) {
        switch index {
        case 1:
            recorder.saveCurrentBuffer()
        case 2:
            recorder.setMode(.buffering)
        case 3:
            recorder.setMode(.recording)
        case 4:
            recorder.setMode(.notInUse)
        default:
            showSettings = true
        }
    }

    private func runClock() async {
        while !Task.isCancelled {
            telemetry.refreshClock()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}


private enum MetadataStyle: String, CaseIterable, Identifiable {
    case stacked
    case compact

    var id: Self { self }

    var title: String {
        switch self {
        case .stacked:
            "Stacked"
        case .compact:
            "Compact"
        }
    }
}


#Preview {
    ContentView()
}
