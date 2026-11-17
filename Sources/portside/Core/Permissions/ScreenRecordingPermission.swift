import CoreGraphics
import Foundation

/// Screen Recording, read with `CGPreflightScreenCaptureAccess`, which never
/// prompts. Asking is `CGRequestScreenCaptureAccess`, called only from a
/// button. The OS reports granted or not, so "not granted" is `denied`.
@MainActor
struct ScreenRecordingPermissionAdapter: PermissionAdapter {
    let scope = PermissionScope.screenRecording
    let canRequest = true

    func currentState() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    func request(forFeature feature: String) -> Bool {
        _ = CGRequestScreenCaptureAccess()
        return true
    }
}
