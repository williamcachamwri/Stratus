import Foundation
import LocalAuthentication
import os.log

// MARK: - BiometricError

public enum BiometricError: Error, Sendable {
    case notAvailable(String)
    case authenticationFailed(String)
    case userCancelled
    case userFallback
    case systemCancel
    case biometryLockout
    case passcodeNotSet
    case biometryNotEnrolled
    case unknownError(Int)
}

// MARK: - BiometricGuard

/// Wraps `LAContext` for Touch ID / Face ID authentication.
///
/// Each `authenticate(reason:)` call creates a fresh `LAContext` to avoid
/// stale policy state after the app is backgrounded.  The actor isolation
/// ensures that concurrent callers serialize their authentication attempts,
/// which is required because `LAContext` is not thread-safe.
public actor BiometricGuard {
    public static let shared = BiometricGuard()

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BiometricGuard")

    private init() {}

    // MARK: - Public API

    /// Returns `true` when biometric authentication is enrolled and available on
    /// this device.  Uses `.deviceOwnerAuthenticationWithBiometrics` so it
    /// returns `false` when biometry is locked out (callers should fall back to
    /// passcode in that case).
    public func canUseBiometrics() async -> Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        if let error {
            logger.info("Biometrics unavailable: \(error.localizedDescription)")
        }
        return canEvaluate
    }

    /// Presents the biometric prompt with the supplied `reason` string.
    ///
    /// - Returns: `true` when the user successfully authenticates.
    /// - Throws: `BiometricError` describing the failure reason.
    ///
    /// Falls back to device passcode if `LAPolicy.deviceOwnerAuthentication`
    /// is used instead; this implementation uses the stricter biometrics-only
    /// policy so the caller retains control over passcode fallback UX.
    public func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "" // Hide "Enter Password" button.

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            let error = policyError.map { mapLAError($0) } ?? BiometricError.notAvailable("Unknown")
            throw error
        }

        do {
            let result = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            logger.info("Biometric authentication \(result ? "succeeded" : "returned false")")
            return result
        } catch {
            let mapped = mapLAError(error as NSError)
            logger.warning("Biometric authentication error: \(error.localizedDescription)")
            throw mapped
        }
    }

    // MARK: - Private

    private func mapLAError(_ error: NSError) -> BiometricError {
        guard error.domain == LAErrorDomain else {
            return BiometricError.unknownError(error.code)
        }
        switch LAError.Code(rawValue: error.code) {
        case .authenticationFailed:
            return .authenticationFailed(error.localizedDescription)
        case .userCancel:
            return .userCancelled
        case .userFallback:
            return .userFallback
        case .systemCancel:
            return .systemCancel
        case .biometryLockout:
            return .biometryLockout
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometryNotEnrolled:
            return .biometryNotEnrolled
        case .biometryNotAvailable:
            return .notAvailable(error.localizedDescription)
        default:
            return .unknownError(error.code)
        }
    }
}

// MARK: - LAContext async shim

private extension LAContext {
    /// Async wrapper for `evaluatePolicy(_:localizedReason:reply:)`.
    func evaluatePolicy(
        _ policy: LAPolicy,
        localizedReason reason: String
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            evaluatePolicy(policy, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
