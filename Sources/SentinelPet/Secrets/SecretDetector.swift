import CryptoKit
import Foundation

enum SecretCategory: String, CaseIterable, Codable, Sendable {
    case privateKey = "private_key", walletSeed = "wallet_seed", githubToken = "github_token"
    case openAIKey = "openai_key", anthropicKey = "anthropic_key", stripeSecretKey = "stripe_secret_key"
    case slackToken = "slack_token", awsCredentials = "aws_credentials"

    var label: String {
        switch self {
        case .privateKey: return "private key"
        case .walletSeed: return "wallet recovery phrase"
        case .githubToken: return "GitHub access token"
        case .openAIKey: return "OpenAI API key"
        case .anthropicKey: return "Anthropic API key"
        case .stripeSecretKey: return "Stripe live secret key"
        case .slackToken: return "Slack access token"
        case .awsCredentials: return "AWS access credentials"
        }
    }
}

/// This is the complete output boundary: no token, fragment, fingerprint,
/// clipboard text or field value can enter a model prompt or activity record.
struct SecretDetection: Codable, Equatable, Sendable {
    let category: SecretCategory
    let count: Int
    let categories: [SecretCategory]
    var label: String { category.label }
}

/// Deliberately recognizes strong credential formats rather than guessing
/// whether an ordinary password, OTP, JWT or hexadecimal value is a secret.
struct SecretDetector {
    static let maximumCharacters = 65_536
    private let wordIndex: [String: Int]
    var hasMnemonicWordlist: Bool { wordIndex.count == 2048 }

    init(englishWords: [String]? = nil) {
        let words: [String]
        if let englishWords { words = englishWords }
        else if let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt"),
                let contents = try? String(contentsOf: url, encoding: .utf8) {
            words = contents.split(whereSeparator: \.isNewline).map(String.init)
        } else { words = [] }
        if words.count == 2048 && Set(words).count == 2048 {
            wordIndex = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        } else { wordIndex = [:] }
    }

    func detect(_ text: String) -> SecretDetection? {
        guard !text.isEmpty, text.utf16.count <= Self.maximumCharacters else { return nil }
        var found: [(SecretCategory, Int)] = []
        let keyCount = privateKeyCount(text)
        if keyCount > 0 { found.append((.privateKey, keyCount)) }
        if validMnemonic(text) { found.append((.walletSeed, 1)) }
        let patterns: [(SecretCategory, String, Int)] = [
            (.githubToken, #"\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,255})(?![A-Za-z0-9_])"#, 4),
            (.openAIKey, #"\bsk-proj-[A-Za-z0-9_-]{40,256}(?![A-Za-z0-9_-])"#, 8),
            (.anthropicKey, #"\bsk-ant-(?:api\d{2}-)?[A-Za-z0-9_-]{40,256}(?![A-Za-z0-9_-])"#, 7),
            (.stripeSecretKey, #"\bsk_live_[A-Za-z0-9]{24,128}(?![A-Za-z0-9])"#, 8),
            (.slackToken, #"\bxox[baprs]-[A-Za-z0-9-]{24,256}(?![A-Za-z0-9-])"#, 5)
        ]
        for (category, pattern, prefix) in patterns {
            let count = Self.matches(pattern, text).filter {
                guard let range = Range($0.range, in: text) else { return false }
                return Self.plausibleToken(String(text[range]), prefixLength: prefix)
            }.prefix(8).count
            if count > 0 { found.append((category, count)) }
        }
        let awsID = !Self.matches(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, text).isEmpty
        let awsSecrets = Self.matches(#"(?i)(?:aws_secret_access_key|secretAccessKey|secret_access_key)["']?\s*[:=]\s*["']?([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"#, text)
        if awsID, awsSecrets.contains(where: {
            guard let range = Range($0.range(at: 1), in: text) else { return false }
            return Self.plausibleToken(String(text[range]), prefixLength: 0)
        }) { found.append((.awsCredentials, 1)) }
        guard let first = found.first else { return nil }
        return SecretDetection(category: first.0, count: min(8, found.reduce(0) { $0 + $1.1 }), categories: found.map(\.0))
    }

    func validMnemonic(_ text: String) -> Bool {
        guard hasMnemonicWordlist, text.utf16.count <= 1024 else { return false }
        let words = text.decomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace)
        guard [12, 15, 18, 21, 24].contains(words.count) else { return false }
        var bits: [UInt8] = []
        for word in words {
            guard let index = wordIndex[String(word)] else { return false }
            for position in stride(from: 10, through: 0, by: -1) { bits.append(UInt8((index >> position) & 1)) }
        }
        let entropyLength = bits.count * 32 / 33
        var entropy = Data(repeating: 0, count: entropyLength / 8)
        for index in 0..<entropyLength { entropy[index / 8] |= bits[index] << (7 - index % 8) }
        let digest = Array(SHA256.hash(data: entropy))
        for index in 0..<(bits.count - entropyLength) {
            if bits[entropyLength + index] != (digest[0] >> (7 - index)) & 1 { return false }
        }
        return true
    }

    private func privateKeyCount(_ text: String) -> Int {
        let pattern = #"-----BEGIN ((?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY)-----([A-Za-z0-9+/=\s]+?)-----END \1-----"#
        return Self.matches(pattern, text).filter { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { return false }
            let encoded = text[bodyRange].filter { !$0.isWhitespace }
            guard encoded.count >= 64, encoded.count % 4 == 0,
                  let data = Data(base64Encoded: String(encoded)) else { return false }
            if text[nameRange] == "OPENSSH PRIVATE KEY" {
                return data.count > 48 && data.starts(with: Data("openssh-key-v1\0".utf8))
            }
            guard data.count >= 48, data[0] == 0x30 else { return false }
            var length = Int(data[1]), offset = 2
            if length & 0x80 != 0 {
                let bytes = length & 0x7f
                guard bytes >= 1, bytes <= 4, bytes + 2 <= data.count else { return false }
                length = 0
                for _ in 0..<bytes { length = length * 256 + Int(data[offset]); offset += 1 }
            }
            return length == data.count - offset
        }.prefix(8).count
    }
    private static func plausibleToken(_ value: String, prefixLength: Int) -> Bool {
        guard matches(#"(?i)(?:example|placeholder|redacted|replace[-_]?me|your[-_]?(?:api|secret|token))"#, value).isEmpty else { return false }
        var prefix = prefixLength
        if value.hasPrefix("github_pat_") { prefix = 11 }
        if value.hasPrefix("sk-ant-api"), let match = matches(#"^sk-ant-api\d{2}-"#, value).first { prefix = match.range.length }
        return Set(value.dropFirst(prefix)).count >= 6
    }
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
