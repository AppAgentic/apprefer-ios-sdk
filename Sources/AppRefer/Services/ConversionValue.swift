import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// SKAdNetwork / AdAttributionKit coarse value.
enum AppReferCoarseValue: String, Sendable, Comparable {
    case low, medium, high

    private var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Sets the install's conversion value on the device (only the app can). Abstracted for tests.
protocol ConversionValueUpdating: Sendable {
    func update(fine: Int, coarse: AppReferCoarseValue) async
}

/// Updates both frameworks: Apple asks apps whose ad networks may use either to call both,
/// and ignores the call when there's no pending postback. Never locks a window early.
struct LiveConversionValueUpdater: ConversionValueUpdating {
    func update(fine: Int, coarse: AppReferCoarseValue) async {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let fine = min(max(fine, 0), 63)
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            let value: AdAttributionKit.CoarseConversionValue = coarse == .high ? .high : coarse == .medium ? .medium : .low
            try? await Postback.updateConversionValue(fine, coarseConversionValue: value, lockPostback: false)
        }
        #endif
        if #available(iOS 16.1, *) {
            let value: SKAdNetwork.CoarseConversionValue = coarse == .high ? .high : coarse == .medium ? .medium : .low
            try? await SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: value, lockWindow: false)
        } else if #available(iOS 15.4, *) {
            try? await SKAdNetwork.updatePostbackConversionValue(fine)
        }
        #endif
    }
}
