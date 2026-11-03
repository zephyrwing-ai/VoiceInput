import Foundation

/// First-run onboarding is a one-time experience. Once it has been presented,
/// later launches only observe permission state and never prompt on their own.
enum OnboardingState {
    private static let key = "VoiceInput.Onboarding.hasBeenShown"

    static var hasBeenShown: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
