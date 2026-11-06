import FanCore
import Foundation
import ServiceManagement

@MainActor
enum HelperService {
    static var service: SMAppService { .daemon(plistName: HelperIdentity.plist) }

    static func prepare() throws {
        guard Bundle.main.bundleIdentifier == HelperIdentity.app,
              Bundle.main.url(forAuxiliaryExecutable: "BreezeHelper") != nil,
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + HelperIdentity.plist).path) else {
            throw FanError("Run the bundled Breeze.app. Build it with scripts/build.sh.")
        }
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                // Registration can report a denied launch while still recording
                // the service for approval. Preserve that useful setup state.
                guard service.status == .requiresApproval else { throw error }
            }
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval:
            throw FanError("Approve Breeze once in System Settings → General → Login Items & Extensions, then apply your profile again.")
        case .notRegistered, .notFound:
            throw FanError("The cooling helper is unavailable. Rebuild the signed Breeze.app and try setup again.")
        @unknown default:
            throw FanError("macOS could not determine the cooling helper’s approval status.")
        }
    }
}
