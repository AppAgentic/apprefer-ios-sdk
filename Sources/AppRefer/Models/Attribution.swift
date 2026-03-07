import Foundation

/// Attribution result returned by `AppRefer.configure()`.
public struct Attribution: Codable, Sendable {
    public let network: String
    public let campaign: String?
    public let matchType: String
    public let attributionId: String?
    public let campaignId: String?
    public let campaignName: String?
    public let adGroupId: String?
    public let adId: String?
    public let keyword: String?
    public let fbclid: String?
    public let gclid: String?
    public let ttclid: String?
    public let queryParams: [String: String]
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case network
        case campaign
        case matchType = "match_type"
        case attributionId = "attribution_id"
        case campaignId = "campaign_id"
        case campaignName = "campaign_name"
        case adGroupId = "ad_group_id"
        case adId = "ad_id"
        case keyword
        case fbclid
        case gclid
        case ttclid
        case queryParams = "query_params"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = (try? container.decode(String.self, forKey: .network)) ?? "unknown"
        campaign = try? container.decode(String.self, forKey: .campaign)
        matchType = (try? container.decode(String.self, forKey: .matchType)) ?? "organic"
        attributionId = try? container.decode(String.self, forKey: .attributionId)
        campaignId = try? container.decode(String.self, forKey: .campaignId)
        campaignName = try? container.decode(String.self, forKey: .campaignName)
        adGroupId = try? container.decode(String.self, forKey: .adGroupId)
        adId = try? container.decode(String.self, forKey: .adId)
        keyword = try? container.decode(String.self, forKey: .keyword)
        fbclid = try? container.decode(String.self, forKey: .fbclid)
        gclid = try? container.decode(String.self, forKey: .gclid)
        ttclid = try? container.decode(String.self, forKey: .ttclid)
        queryParams = (try? container.decode([String: String].self, forKey: .queryParams)) ?? [:]

        if let dateString = try? container.decode(String.self, forKey: .createdAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                createdAt = date
            } else {
                let basicFormatter = ISO8601DateFormatter()
                createdAt = basicFormatter.date(from: dateString) ?? Date()
            }
        } else {
            createdAt = Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(network, forKey: .network)
        try container.encodeIfPresent(campaign, forKey: .campaign)
        try container.encode(matchType, forKey: .matchType)
        try container.encodeIfPresent(attributionId, forKey: .attributionId)
        try container.encodeIfPresent(campaignId, forKey: .campaignId)
        try container.encodeIfPresent(campaignName, forKey: .campaignName)
        try container.encodeIfPresent(adGroupId, forKey: .adGroupId)
        try container.encodeIfPresent(adId, forKey: .adId)
        try container.encodeIfPresent(keyword, forKey: .keyword)
        try container.encodeIfPresent(fbclid, forKey: .fbclid)
        try container.encodeIfPresent(gclid, forKey: .gclid)
        try container.encodeIfPresent(ttclid, forKey: .ttclid)
        try container.encode(queryParams, forKey: .queryParams)
        let formatter = ISO8601DateFormatter()
        try container.encode(formatter.string(from: createdAt), forKey: .createdAt)
    }

    /// Internal initializer for testing.
    internal init(
        network: String,
        campaign: String? = nil,
        matchType: String,
        attributionId: String? = nil,
        campaignId: String? = nil,
        campaignName: String? = nil,
        adGroupId: String? = nil,
        adId: String? = nil,
        keyword: String? = nil,
        fbclid: String? = nil,
        gclid: String? = nil,
        ttclid: String? = nil,
        queryParams: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.network = network
        self.campaign = campaign
        self.matchType = matchType
        self.attributionId = attributionId
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.adGroupId = adGroupId
        self.adId = adId
        self.keyword = keyword
        self.fbclid = fbclid
        self.gclid = gclid
        self.ttclid = ttclid
        self.queryParams = queryParams
        self.createdAt = createdAt
    }
}
