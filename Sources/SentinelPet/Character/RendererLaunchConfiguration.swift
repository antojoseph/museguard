import Foundation

/// Release builds launch only the helper shipped inside the signed app bundle.
/// An absolute editor/project pair is intentionally a development-only format.
struct RendererLaunchConfiguration {
    let executableURL: URL
    let arguments: [String]

    static let packagedArguments = [
        "/Game/Maps/MuseStage", "-game", "-RenderOffscreen", "-windowed",
        "-ResX=448", "-ResY=448", "-nosound", "-unattended", "-NoSplash", "-NoLoadingScreen"
    ]

    enum ConfigurationError: Error {
        case invalidFormat, unsupportedVersion, invalidExecutable, invalidArguments, editorNotAllowed
    }

    private struct Document: Decodable {
        let version: Int?
        let executable: String
        let arguments: [String]?
        let project: String?
    }

    static func decode(_ data: Data, bundleURL: URL, allowEditorDevelopment: Bool = false,
                       fileManager: FileManager = .default) throws -> RendererLaunchConfiguration {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw ConfigurationError.invalidFormat
        }
        if document.version == nil {
            guard allowEditorDevelopment else { throw ConfigurationError.editorNotAllowed }
            guard document.executable.hasPrefix("/"),
                  ["UnrealEditor", "UnrealEditor-Cmd"].contains(URL(fileURLWithPath: document.executable).lastPathComponent),
                  fileManager.isExecutableFile(atPath: document.executable),
                  let project = document.project, project.hasPrefix("/"),
                  URL(fileURLWithPath: project).pathExtension == "uproject",
                  fileManager.fileExists(atPath: project) else {
                throw ConfigurationError.invalidExecutable
            }
            return RendererLaunchConfiguration(executableURL: URL(fileURLWithPath: document.executable),
                                               arguments: [project] + packagedArguments)
        }
        guard document.version == 2 else { throw ConfigurationError.unsupportedVersion }
        // Reject even normalized traversal: only a direct helper executable is supported.
        let parts = document.executable.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, Array(parts.prefix(5)) == ["Contents", "Helpers", "MuseRenderer.app", "Contents", "MacOS"],
              let executableName = parts.last, !executableName.isEmpty,
              executableName != ".", executableName != "..", !executableName.contains("\\"),
              document.project == nil else { throw ConfigurationError.invalidExecutable }
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let executable = bundle.appendingPathComponent(document.executable).standardizedFileURL.resolvingSymlinksInPath()
        let helperDirectory = bundle.appendingPathComponent("Contents/Helpers/MuseRenderer.app/Contents/MacOS", isDirectory: true)
        guard executable.deletingLastPathComponent() == helperDirectory,
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fileManager.isExecutableFile(atPath: executable.path) else { throw ConfigurationError.invalidExecutable }
        guard document.arguments == packagedArguments else { throw ConfigurationError.invalidArguments }
        return RendererLaunchConfiguration(executableURL: executable, arguments: packagedArguments)
    }
}
