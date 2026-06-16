import SwiftUI

struct AnalysisLogsView: View {
    @ObservedObject var runtime: SentinelPetRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LLM Judging Logs")
                        .font(.title2.weight(.semibold))
                    Text("Session history of Fireworks verdicts and model errors. Raw screen text and screenshots are not stored here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Clear") {
                    runtime.clearAnalysisLogs()
                }
                .disabled(runtime.analysisLogs.isEmpty)
            }

            Divider()

            if runtime.analysisLogs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No judgements yet")
                        .font(.headline)
                    Text("Run focused-window, screenshot, or monitoring analysis to populate this log.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runtime.analysisLogs) { entry in
                            AnalysisLogEntryView(entry: entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct AnalysisLogEntryView: View {
    let entry: AnalysisLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(entry.source.label, systemImage: entry.source.systemImage)
                    .font(.headline)

                if entry.includesScreenshot {
                    Label("Image", systemImage: "photo")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("App")
                        .foregroundStyle(.secondary)
                    Text(entry.appName)
                }

                if let windowTitle = entry.windowTitle, !windowTitle.isEmpty {
                    GridRow {
                        Text("Window")
                            .foregroundStyle(.secondary)
                        Text(windowTitle)
                    }
                }

                GridRow {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    Text(entry.model)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .font(.caption)

            if let verdict = entry.verdict {
                HStack(spacing: 8) {
                    Text(verdict.riskLevel.rawValue.uppercased())
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(riskColor(for: verdict.riskLevel).opacity(0.18))
                        .foregroundStyle(riskColor(for: verdict.riskLevel))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    if !verdict.categories.isEmpty {
                        Text(verdict.categories.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(verdict.summary)
                    Text(verdict.guidance)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .textSelection(.enabled)
            }

            if let errorMessage = entry.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func riskColor(for riskLevel: RiskLevel) -> Color {
        switch riskLevel {
        case .safe:
            return .green
        case .low:
            return .teal
        case .medium, .unknown:
            return .orange
        case .high:
            return .red
        }
    }
}
