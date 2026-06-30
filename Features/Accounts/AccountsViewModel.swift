import Foundation
import StratusCore
import SwiftUI

@MainActor
public final class AccountsViewModel: ObservableObject {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let providerID: String
        public let title: String
        public let subtitle: String
        public let health: Health

        public enum Health: String, Equatable {
            case ready = "Ready"
            case needsAttention = "Needs attention"
            case offline = "Offline"
        }
    }

    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var selectedAccountID: String?

    private let environment: AppEnvironment

    public init(environment: AppEnvironment = .shared) {
        self.environment = environment
        refresh()
    }

    public func refresh() {
        rows = environment.accounts.map { account in
            Row(
                id: account.id,
                providerID: account.providerID,
                title: account.displayName,
                subtitle: account.email ?? account.providerID.uppercased(),
                health: environment.isOnline ? .ready : .offline
            )
        }
    }

    public func select(accountID: String?) {
        selectedAccountID = accountID
    }
}
