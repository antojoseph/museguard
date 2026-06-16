import Foundation

enum RiskLevel: String, Codable {
    case safe
    case low
    case medium
    case high
    case unknown

    var severity: Int {
        switch self {
        case .safe:    return 0
        case .low:     return 1
        case .medium:  return 2
        case .high:    return 3
        case .unknown: return 2
        }
    }
}

enum AlertSensitivity: String, CaseIterable, Identifiable {
    case low
    case standard
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low:      return "Low"
        case .standard: return "Standard"
        case .high:     return "High"
        }
    }

    var minimumRiskLevel: RiskLevel {
        switch self {
        case .low:      return .high
        case .standard: return .medium
        case .high:     return .low
        }
    }

    func shouldInterrupt(for riskLevel: RiskLevel) -> Bool {
        riskLevel == .unknown || riskLevel.severity >= minimumRiskLevel.severity
    }
}

struct RiskVerdict: Codable {
    let riskLevel: RiskLevel
    let summary: String
    let guidance: String
    let categories: [String]

    enum CodingKeys: String, CodingKey {
        case riskLevel = "risk_level"
        case summary
        case guidance
        case categories
    }
}
