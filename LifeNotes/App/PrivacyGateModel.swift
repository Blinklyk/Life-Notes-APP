import Combine
import Foundation
import LocalAuthentication

@MainActor
final class PrivacyGateModel: ObservableObject {
    enum State: Equatable {
        case locked
        case authenticating
        case unlocked
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .locked
    private var activeContext: LAContext?
    private var authenticationID: UUID?

    func unlock() async {
        guard state != .authenticating, state != .unlocked else {
            return
        }

        let requestID = UUID()
        let context = LAContext()
        context.localizedCancelTitle = "稍后"
        activeContext = context
        authenticationID = requestID
        var evaluationError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            activeContext = nil
            authenticationID = nil
            state = .unavailable(unavailableMessage(for: evaluationError))
            return
        }

        state = .authenticating

        do {
            let succeeded = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "解锁并查看你的随心记录"
            )
            guard authenticationID == requestID else {
                return
            }
            activeContext = nil
            authenticationID = nil
            state = succeeded ? .unlocked : .failed("未能验证身份，请重试。")
        } catch let error as LAError {
            guard authenticationID == requestID else {
                return
            }
            activeContext = nil
            authenticationID = nil
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                state = .locked
            default:
                state = .failed("未能验证身份，请重试。")
            }
        } catch {
            guard authenticationID == requestID else {
                return
            }
            activeContext = nil
            authenticationID = nil
            state = .failed("未能验证身份，请重试。")
        }
    }

    func lock() {
        authenticationID = nil
        activeContext?.invalidate()
        activeContext = nil
        state = .locked
    }

    private func unavailableMessage(for error: NSError?) -> String {
        guard let error, let laError = error as? LAError else {
            return "此设备暂时无法进行身份验证。"
        }

        switch laError.code {
        case .biometryNotEnrolled, .passcodeNotSet:
            return "请先在系统中设置 Face ID 或设备密码。"
        case .biometryLockout:
            return "Face ID 已锁定，请先使用设备密码解锁。"
        default:
            return "此设备暂时无法进行身份验证。"
        }
    }
}
