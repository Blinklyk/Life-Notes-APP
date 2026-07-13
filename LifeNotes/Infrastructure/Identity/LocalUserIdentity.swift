import Foundation

enum LocalUserIdentity {
    private static let userIDKey = "localUserID"

    static func loadOrCreate(in defaults: UserDefaults = .standard) -> UUID {
        if let storedValue = defaults.string(forKey: userIDKey),
           let storedID = UUID(uuidString: storedValue) {
            return storedID
        }

        let newID = UUID()
        defaults.set(newID.uuidString, forKey: userIDKey)
        return newID
    }
}
