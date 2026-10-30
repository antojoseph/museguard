import AppKit
import CryptoKit
import Foundation

@main struct SecretDetectionChecks {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: "Sources/SentinelPet/Secrets/bip39-english.txt")
        let data = try Data(contentsOf: url)
        assert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
            "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
        let words = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let detector = SecretDetector(englishWords: words)
        assert(detector.hasMnemonicWordlist)
        let seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert(detector.validMnemonic(seed))
        assert(detector.validMnemonic("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"))
        assert(!detector.validMnemonic(String(repeating: "abandon ", count: 12)))
        assert(detector.detect(seed)?.category == .walletSeed)
        for size in [16, 20, 24, 28, 32] {
            let entropy = Data((0..<size).map { UInt8(($0 * 37 + size) % 256) })
            let checksum = Array(SHA256.hash(data: entropy))[0]
            var bits: [Int] = []
            for byte in entropy { for bit in stride(from: 7, through: 0, by: -1) { bits.append(Int((byte >> bit) & 1)) } }
            for bit in stride(from: 7, through: 8 - size / 4, by: -1) { bits.append(Int((checksum >> bit) & 1)) }
            let sentence = stride(from: 0, to: bits.count, by: 11).map { start -> String in
                let index = bits[start..<(start + 11)].reduce(0) { $0 * 2 + $1 }
                return words[index]
            }.joined(separator: " ")
            assert(detector.validMnemonic(sentence), "All BIP39 entropy lengths must validate.")
        }
        let suffix = "aB3dE5gH7jK9mN2pQ4sT6vW8xY0zC1fR3uV5"
        let token = "ghp_" + suffix
        let fixtures: [(String, SecretCategory)] = [
            (token, .githubToken), ("github_pat_" + suffix + suffix, .githubToken),
            ("sk-proj-" + suffix + suffix, .openAIKey), ("sk-ant-api03-" + suffix + suffix, .anthropicKey),
            ("sk_live_" + suffix, .stripeSecretKey), ("xoxb-" + suffix, .slackToken),
            ("aws_access_key_id=AKIA1234567890ABCDEF\naws_secret_access_key=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd", .awsCredentials)
        ]
        for (text, category) in fixtures {
            guard let result = detector.detect(text) else { fatalError("Expected synthetic credential format") }
            assert(result.category == category)
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            assert(!encoded.contains(text) && !encoded.contains("aB3dE5gH"), "No literal secret can cross the detector boundary.")
        }
        let der = Data([0x30, 0x3e] + Array(repeating: UInt8(1), count: 62))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + der.base64EncodedString() + "\n-----END PRIVATE KEY-----"
        assert(detector.detect(pem)?.category == .privateKey)
        assert(detector.detect(String(repeating: "ghp_" + String(repeating: "x", count: 36) + "\n", count: 10) + token)?.category == .githubToken)
        for value in ["ordinary-password!123", "123456", "AKIA1234567890ABCDEF", "0x" + String(repeating: "abcdef0123456789", count: 4),
                      "github_pat_" + String(repeating: "x", count: 80), "sk-ant-api03-" + String(repeating: "A", count: 64),
                      "sk-proj-" + String(repeating: "x", count: 64), "sk_test_" + suffix,
                      "-----BEGIN PUBLIC KEY-----\n" + der.base64EncodedString() + "\n-----END PUBLIC KEY-----",
                      String(repeating: "x", count: 65537)] {
            assert(detector.detect(value) == nil, "Ordinary values, public identifiers and malformed/examples must remain untouched.")
        }
        let missing = SecretDetector(englishWords: [])
        assert(!missing.hasMnemonicWordlist && missing.detect(seed) == nil && missing.detect(token)?.category == .githubToken)

        func event(_ flags: NSEvent.ModifierFlags, repeatKey: Bool = false, code: UInt16 = 9, characters: String = "v") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeatKey, keyCode: code)!
        }
        assert(NativeSecretPasteMonitor.isPaste(event(.command)))
        assert(NativeSecretPasteMonitor.isPaste(event([.command, .shift])))
        assert(!NativeSecretPasteMonitor.isPaste(event([.command, .control])))
        assert(!NativeSecretPasteMonitor.isPaste(event([.command, .option])))
        assert(!NativeSecretPasteMonitor.isPaste(event(.command, repeatKey: true)))
        assert(!NativeSecretPasteMonitor.isPaste(event([], code: 9)))
        assert(!NativeSecretPasteMonitor.isPaste(event(.command, code: 8, characters: "c")))
        print("PASS: native secret formats, BIP39 checksum/wordlist, metadata-only output, ordinary-value exclusions and Command+V observation policy")
    }
}
