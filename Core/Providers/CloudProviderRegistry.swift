import Foundation

// MARK: - CloudProviderRegistry Extensions
// The CloudProviderRegistry actor is declared in CloudProvider.swift.
// This file adds convenience accessors matching the documented labeled-parameter interface.

public extension CloudProviderRegistry {

    /// Labeled-parameter form of `register(_:)` for call-site clarity.
    func register(provider: any CloudProvider) {
        register(provider)
    }

    /// Labeled async lookup — sugar over the synchronous `provider(id:)` for
    /// callers that need to await into the actor's context.
    func asyncProvider(id: String) async -> (any CloudProvider)? {
        provider(id: id)
    }

    /// Async snapshot of every registered provider.
    func allProvidersAsync() async -> [any CloudProvider] {
        allProviders
    }
}
