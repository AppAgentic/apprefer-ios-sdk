import Foundation
import StoreKit

/// Arbitrary JSON metadata, preserving nested objects, arrays and nulls.
public enum OfferingJSON: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: OfferingJSON]), array([OfferingJSON]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: OfferingJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([OfferingJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v) }
    }
}
public enum AppReferPackageType: String, Codable, Sendable {
    case weekly, monthly, twoMonth, threeMonth, sixMonth, annual, lifetime, custom, unknown
    static func resolve(identifier: String, raw: String?) -> Self {
        let aliases: [String: Self] = ["weekly": .weekly, "monthly": .monthly, "two_month": .twoMonth, "three_month": .threeMonth, "six_month": .sixMonth, "annual": .annual, "lifetime": .lifetime, "twoMonth": .twoMonth, "threeMonth": .threeMonth, "sixMonth": .sixMonth]
        if identifier.hasPrefix("$ar_") || identifier.hasPrefix("$rc_") { return aliases[String(identifier.dropFirst(4))] ?? .custom }
        return raw.flatMap { aliases[$0] } ?? .custom
    }
}
public struct OfferingContext: Codable, Sendable, Equatable {
    public var targetingRuleId: String?
    public var experimentId: String?
    public var variantId: String?
}
public struct PresentedOfferingContext: Codable, Sendable, Equatable {
    public let offeringId: String
    public let packageId: String
    public var placementId: String?
    public let targetingRuleId: String?
    public let experimentId: String?
    public let variantId: String?
    var dictionary: [String: String] {
        var d = ["offeringId": offeringId, "packageId": packageId]
        d["placementId"] = placementId; d["targetingRuleId"] = targetingRuleId
        d["experimentId"] = experimentId; d["variantId"] = variantId
        return d
    }
}
public struct AppReferPackage: Sendable {
    public let identifier: String
    public let packageType: AppReferPackageType
    public let storeProduct: Product
    public let offeringIdentifier: String
    public var presentedOfferingContext: PresentedOfferingContext
}
public struct AppReferOffering: Sendable {
    public let identifier: String
    public let displayName: String
    public let metadata: [String: OfferingJSON]
    public var availablePackages: [AppReferPackage]
    public func package(identifier: String) -> AppReferPackage? { availablePackages.first { $0.identifier == identifier } }
    public var weekly: AppReferPackage? { availablePackages.first { $0.packageType == .weekly } }
    public var monthly: AppReferPackage? { availablePackages.first { $0.packageType == .monthly } }
    public var twoMonth: AppReferPackage? { availablePackages.first { $0.packageType == .twoMonth } }
    public var threeMonth: AppReferPackage? { availablePackages.first { $0.packageType == .threeMonth } }
    public var sixMonth: AppReferPackage? { availablePackages.first { $0.packageType == .sixMonth } }
    public var annual: AppReferPackage? { availablePackages.first { $0.packageType == .annual } }
    public var lifetime: AppReferPackage? { availablePackages.first { $0.packageType == .lifetime } }
    func forPlacement(_ id: String) -> Self {
        var copy = self
        copy.availablePackages = availablePackages.map { var p = $0; p.presentedOfferingContext.placementId = id; return p }
        return copy
    }
}
public struct AppReferOfferings: Sendable {
    public let current: AppReferOffering?
    public let all: [String: AppReferOffering]
    public let context: OfferingContext
    let placements: [String: String?]
    public func currentOffering(forPlacement placement: String) -> AppReferOffering? {
        if let configured = placements[placement] {
            guard let id = configured else { return nil }
            return all[id]?.forPlacement(placement)
        }
        return current?.forPlacement(placement)
    }
}
struct CachedOfferings: Codable, Sendable { let response: OfferingsResponse; var fetchedAt: Date }
struct OfferingsResponse: Codable, Sendable {
    struct Offering: Codable, Sendable {
        struct Package: Codable, Sendable { let id: String; let packageType: String?; let productId: String? }
        let id: String; let displayName: String?; let metadata: [String: OfferingJSON]?; let packages: [Package]
    }
    let currentOfferingId: String?
    let offerings: [Offering]
    let placements: [String: String?]
    let context: OfferingContext
    let requestDateMs: Double
    func resolve(products: @Sendable ([String]) async throws -> [Product]) async throws -> AppReferOfferings {
        let ids = Array(Set(offerings.flatMap { $0.packages.compactMap(\.productId) }))
        let loaded = (try? await products(ids)) ?? []
        let byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var all: [String: AppReferOffering] = [:]
        for o in offerings {
            let packages: [AppReferPackage] = o.packages.compactMap { p in
                guard let id = p.productId, let product = byId[id] else { return nil }
                return AppReferPackage(identifier: p.id, packageType: .resolve(identifier: p.id, raw: p.packageType), storeProduct: product, offeringIdentifier: o.id, presentedOfferingContext: PresentedOfferingContext(offeringId: o.id, packageId: p.id, targetingRuleId: context.targetingRuleId, experimentId: context.experimentId, variantId: context.variantId))
            }
            all[o.id] = AppReferOffering(identifier: o.id, displayName: o.displayName ?? o.id, metadata: o.metadata ?? [:], availablePackages: packages)
        }
        return AppReferOfferings(current: currentOfferingId.flatMap { all[$0] }, all: all, context: context, placements: placements)
    }
}
