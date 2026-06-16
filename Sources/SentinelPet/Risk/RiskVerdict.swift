import Foundation

enum RiskLevel: String, Codable {
    case safe
    case low
    case medium
    case high
    case unknown
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
