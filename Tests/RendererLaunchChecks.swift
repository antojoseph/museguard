import Foundation

@main
struct RendererLaunchChecks {
    static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("muse-launch-check-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Muse Guard.app", isDirectory: true)
        let relative = "Contents/Helpers/MuseRenderer.app/Contents/MacOS/MuseGuard-Mac-Shipping"
        let executable = bundle.appendingPathComponent(relative)
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        func document(_ executable: String = relative, _ arguments: [String] = RendererLaunchConfiguration.packagedArguments,
                      version: Int = 2) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": version, "executable": executable, "arguments": arguments])
        }
        func rejects(_ data: Data) {
            do { _ = try RendererLaunchConfiguration.decode(data, bundleURL: bundle); fatalError("Accepted invalid renderer configuration") }
            catch { }
        }
        let config = try RendererLaunchConfiguration.decode(document(), bundleURL: bundle)
        precondition(config.executableURL == executable && config.arguments == RendererLaunchConfiguration.packagedArguments)
        rejects(try document(executable.path))
        rejects(try document("../MuseGuard-Mac-Shipping"))
        rejects(try document("Contents/Helpers/MuseRenderer.app/Contents/MacOS/../MacOS/MuseGuard-Mac-Shipping"))
        rejects(try document("Contents/Helpers/Other.app/Contents/MacOS/MuseGuard-Mac-Shipping"))
        rejects(try document("Contents/Helpers/MuseRenderer.app/Contents/MacOS/Missing"))
        rejects(try document(version: 3))
        rejects(try document(relative, RendererLaunchConfiguration.packagedArguments + ["-ExecCmds=quit"]))
        rejects(try document(relative, []))
        rejects(Data("{}".utf8))
        let external = directory.appendingPathComponent("UnrealEditor-Cmd")
        try manager.copyItem(at: executable, to: external)
        let symlink = executable.deletingLastPathComponent().appendingPathComponent("EscapedRenderer")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: external)
        rejects(try document("Contents/Helpers/MuseRenderer.app/Contents/MacOS/EscapedRenderer"))
        let project = directory.appendingPathComponent("MuseGuard.uproject")
        try Data("{}".utf8).write(to: project)
        let legacy = try JSONSerialization.data(withJSONObject: ["executable": external.path, "project": project.path])
        rejects(legacy)
        let development = try RendererLaunchConfiguration.decode(legacy, bundleURL: bundle, allowEditorDevelopment: true)
        precondition(development.executableURL == external && development.arguments.first == project.path)
        print("Renderer launch configuration checks passed")
    }
}
