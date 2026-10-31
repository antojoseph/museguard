import SwiftUI

/// A read-only view of the prediction selected for the current source. The
/// runtime owns source correlation and freshness; this view never reads page
/// evidence, the screen, clipboard contents, or historical analysis logs.
struct PredictionDebugView: View {
    @ObservedObject var viewModel: PetViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let snapshot = viewModel.predictionDebug
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                    Text("MODEL ACTIVITY").tracking(0.6)
                    Spacer(minLength: 4)
                    Text(status(snapshot.phase))
                    if let date = snapshot.timestamp {
                        Text(age(date, now: timeline.date)).monospacedDigit()
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))

                Text(display(snapshot.heading, limit: 100))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    if snapshot.phase == .completed {
                        Text((snapshot.riskLevel ?? .unknown).rawValue.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(riskColor(snapshot.riskLevel ?? .unknown))
                    } else {
                        Text("NO CURRENT VERDICT")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer(minLength: 0)
                    Text(source(snapshot.kind))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                Text(snapshot.phase == .completed
                    ? display(snapshot.summary ?? "No summary was returned.", limit: 180)
                    : display(snapshot.statusDetail ?? explanation(snapshot.phase), limit: 180))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.075, green: 0.10, blue: 0.16).opacity(0.97),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.17), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
        .allowsHitTesting(false)
    }

    private func status(_ phase: PredictionDebugPhase) -> String {
        switch phase {
        case .waiting: return "Waiting"
        case .checking: return "Checking"
        case .completed: return "Finished"
        case .unavailable: return "Unavailable"
        case .paused: return "Paused"
        case .stale: return "Stale"
        case .stopped: return "Stopped"
        }
    }
    private func explanation(_ phase: PredictionDebugPhase) -> String {
        switch phase {
        case .waiting: return "Waiting for the current activity."
        case .checking: return "The local model is checking the current source."
        case .completed: return "No summary was returned."
        case .unavailable: return "Current activity could not be assessed."
        case .paused: return "Automatic monitoring is paused."
        case .stale: return "Waiting for a fresh prediction."
        case .stopped: return "Automatic monitoring is stopped."
        }
    }
    private func source(_ kind: PredictionDebugSourceKind?) -> String {
        switch kind {
        case .browser: return "Chrome tab"
        case .desktopText: return "Window text"
        case .desktopVisual: return "Window image"
        case nil: return "Current activity"
        }
    }
    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .safe: return Color(red: 0.45, green: 0.88, blue: 0.66)
        case .low: return Color(red: 0.43, green: 0.83, blue: 0.88)
        case .medium: return Color(red: 1, green: 0.77, blue: 0.35)
        case .high: return Color(red: 1, green: 0.49, blue: 0.48)
        case .unknown: return Color.white.opacity(0.72)
        }
    }
    private func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 1 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
    private func display(_ value: String, limit: Int) -> String {
        let text = String(value.prefix(600))
            .replacingOccurrences(of: #"https?://[^\s<>"']+"#, with: "[link]", options: .regularExpression)
        return String(text.unicodeScalars.filter {
            (!CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)) &&
                !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }.map(String.init).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }
}

/// Debug placement never changes the avatar's anchor or the warning card.
/// It prefers the head's upper edge and yields when no separate space exists.
enum PredictionDebugPlacement {
    static let size = CGSize(width: 300, height: 132)

    static func frame(avatar: CGRect, screen: CGRect, avoiding obstacles: [CGRect]) -> CGRect? {
        guard !avatar.isNull, avatar.width > 0, avatar.height > 0,
              screen.width > 12, screen.height > 12 else { return nil }
        let safe = screen.insetBy(dx: 6, dy: 6)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let gap: CGFloat = 8
        let centerX = avatar.midX - width / 2
        let origins = [
            CGPoint(x: centerX, y: avatar.maxY + gap),
            CGPoint(x: avatar.maxX - width, y: avatar.maxY + gap),
            CGPoint(x: avatar.minX, y: avatar.maxY + gap),
            CGPoint(x: avatar.maxX + gap, y: avatar.maxY - height),
            CGPoint(x: avatar.minX - width - gap, y: avatar.maxY - height),
            CGPoint(x: centerX, y: avatar.minY - height - gap)
        ]
        for origin in origins {
            let rect = CGRect(x: min(max(origin.x, safe.minX), safe.maxX - width),
                y: min(max(origin.y, safe.minY), safe.maxY - height), width: width, height: height)
            if !rect.intersects(avatar.insetBy(dx: -4, dy: -4)) &&
                !obstacles.contains(where: { rect.intersects($0.insetBy(dx: -6, dy: -6)) }) { return rect }
        }
        return nil
    }
}
