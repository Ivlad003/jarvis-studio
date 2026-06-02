import CoreGraphics

enum StartupPermissionPolicy {
    static let screenRecordingDeniedWarning = "Screen Recording permission is not granted. Audio-only recording will work; Audio + Screen needs System Settings -> Privacy & Security -> Screen Recording."

    static func screenRecordingGranted(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) -> Bool {
        preflight()
    }

    static func screenRecordingWarning(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) -> String? {
        screenRecordingGranted(preflight: preflight) ? nil : screenRecordingDeniedWarning
    }
}
