import Foundation

@main struct BuildConfigurationChecks {
    static func main() {
        let expected = CommandLine.arguments.contains("--expect-enabled")
        precondition(CommandLine.arguments.contains("--visual-test"), "Exercise the actual capture-test override")
        precondition(BuildConfiguration.visualTestingEnabled == expected,
                     "Release builds must ignore the development-only capture override")
        print("PASS: capture-test override is \(expected ? "available in development" : "disabled in release")")
    }
}
