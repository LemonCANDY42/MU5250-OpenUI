import Foundation

actor SessionVault {
    private var token: String?

    func value() -> String? {
        token
    }

    func replace(with token: String) {
        self.token = token
    }

    func clear() {
        token = nil
    }
}
