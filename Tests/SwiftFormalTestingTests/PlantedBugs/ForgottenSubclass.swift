// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 10: a mapper over a sealed hierarchy from a binary framework forgets a subclass.
//
// The classes stand in for a Kotlin `sealed class` a framework exports through SKIE: a base class, a final subclass
// per case (a Kotlin `object` is a singleton with `shared`), and an `onEnum(of:)` switch over the subclasses. The
// walk's domain is generated from the framework's symbol graph by `sfgen domains` (GeneratedBinaryDomains.swift).

class Reward {}

final class RewardNone: Reward {
    static var shared: RewardNone { RewardNone() }
    override private init() {}
}

final class RewardPoints: Reward {
    let doubled: Bool
    init(doubled: Bool) { self.doubled = doubled }
}

final class RewardVoucher: Reward {
    let expired: Bool
    init(expired: Bool) { self.expired = expired }
}

enum RewardKind {
    case none(RewardNone)
    case points(RewardPoints)
    case voucher(RewardVoucher)
}

func onEnum(of reward: Reward) -> RewardKind {
    if let points = reward as? RewardPoints { return .points(points) }
    if let voucher = reward as? RewardVoucher { return .voucher(voucher) }
    return .none(RewardNone.shared)
}

/// The text of a reward. The planted bug casts for the subclasses it remembers and lets a voucher fall through to
/// the text for no reward.
func rewardTextBuggy(_ reward: Reward) -> String {
    if let points = reward as? RewardPoints { return points.doubled ? "double points" : "points" }
    return "no reward"
}

func rewardTextFixed(_ reward: Reward) -> String {
    switch onEnum(of: reward) {
    case .none: "no reward"
    case .points(let points): points.doubled ? "double points" : "points"
    case .voucher(let voucher): voucher.expired ? "expired voucher" : "voucher"
    }
}

// Only the reward that is no reward reads as none.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15rewardTextBuggy6VerifyfMp_.swift", line: 1)
func rewardTextBuggy_ensures(_ reward: Reward, _ text: String) -> Bool { (text == "no reward") == (reward is RewardNone) }
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs15rewardTextFixed6VerifyfMp_.swift", line: 1)
func rewardTextFixed_ensures(_ reward: Reward, _ text: String) -> Bool { (text == "no reward") == (reward is RewardNone) }
#sourceLocation()
