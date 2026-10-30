import SwiftUI

struct AnalysisLogsView: View {
    @ObservedObject var runtime: SentinelPetRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent activity").font(.title2.weight(.semibold))
                    Text("Checks and errors from this session. Screen text and screenshots are not saved in this list.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Clear activity") { runtime.clearAnalysisLogs() }
                    .disabled(runtime.analysisLogs.isEmpty)
            }
            Divider()
            if runtime.analysisLogs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No recent checks").font(.headline)
                    Text("Automatic browser and desktop checks will appear here as they finish.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runtime.analysisLogs) { entry in
                            ActivityEntryView(entry: entry)
                        }
                    }.padding(.vertical, 2)
                }
            }
        }.padding(20).frame(minWidth: 640, minHeight: 460)
    }
}

private struct ActivityEntryView: View {
    let entry: AnalysisLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(sourceLabel, systemImage: entry.source.systemImage).font(.headline)
                Spacer()
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(resultLabel).font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.errorMessage != nil ? Color.secondary : Color.primary)
                if let title = entry.windowTitle, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(entry.errorMessage ?? entry.verdict?.summary ?? "Check completed.")
                .font(.callout).textSelection(.enabled)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App: \(entry.appName)")
                    if let title = entry.windowTitle, !title.isEmpty { Text("Window: \(title)") }
                    if let verdict = entry.verdict {
                        Text("Assessment: \(verdict.riskLevel.rawValue)")
                        if !verdict.guidance.isEmpty { Text(verdict.guidance) }
                        if !verdict.categories.isEmpty { Text("Categories: \(verdict.categories.joined(separator: ", "))") }
                    }
                    Text("Engine: \(entry.model)").font(.system(.caption, design: .monospaced))
                    if entry.includesScreenshot { Text("This check included an image.") }
                }.font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 6)
            }.font(.caption)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sourceLabel: String {
        switch entry.source {
        case .downloadInspection: return "Download inspection"
        case .secretPaste: return "Secret paste protection"
        case .browserText: return "Browser check"
        case .monitorScreenshot: return "Desktop visual check"
        case .monitorText: return "Desktop text check"
        #if MUSE_DEVELOPMENT
        case .mock: return "Example check"
        #endif
        }
    }
    private var resultLabel: String {
        guard entry.errorMessage == nil, let verdict = entry.verdict else { return "Check unavailable" }
        switch verdict.riskLevel {
        case .high: return "Concern found"
        case .unknown: return "Could not assess"
        case .safe, .low, .medium: return "No high-risk concern found"
        }
    }
}
