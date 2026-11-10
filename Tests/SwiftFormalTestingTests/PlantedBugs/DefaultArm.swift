// swift-format-ignore-file
// (swift-format would strip the spaces in the `#sourceLocation` markers below.)
// Planted-bug suite, shape 6: a `default:` arm silently takes a case that has its own output.

enum OrderStatus: CaseIterable {
    case draft, submitted, approved, rejected, archived
}

enum Badge: Hashable {
    case none, pending, success, failure
}

/// A submitted order should show `.pending`; the `default:` arm gives it `.none`.
func badgeBuggy(_ status: OrderStatus) -> Badge {
    switch status {
    case .approved: .success
    case .rejected: .failure
    default: .none
    }
}

func badgeFixed(_ status: OrderStatus) -> Badge {
    switch status {
    case .submitted: .pending
    case .approved: .success
    case .rejected: .failure
    case .draft, .archived: .none
    }
}

// Only orders that are not under way show no badge.
#sourceLocation(file: "@__swiftmacro_11PlantedBugs10badgeBuggy6VerifyfMp_.swift", line: 1)
func badgeBuggy_ensures(_ status: OrderStatus, _ badge: Badge) -> Bool {
    (badge == .none) == (status == .draft || status == .archived)
}
#sourceLocation()
#sourceLocation(file: "@__swiftmacro_11PlantedBugs10badgeFixed6VerifyfMp_.swift", line: 1)
func badgeFixed_ensures(_ status: OrderStatus, _ badge: Badge) -> Bool {
    (badge == .none) == (status == .draft || status == .archived)
}
#sourceLocation()
