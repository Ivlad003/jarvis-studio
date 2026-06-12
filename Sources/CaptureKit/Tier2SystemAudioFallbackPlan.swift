enum Tier2SystemAudioFallbackPlan {
    static func shouldStartSCKit(
        systemAudioEnabled: Bool,
        hasSystemTask: Bool,
        hasDeviceAudioCapture: Bool,
        hasProcessTap: Bool,
        hasSCKitCapture: Bool
    ) -> Bool {
        systemAudioEnabled
            && !hasSystemTask
            && !hasDeviceAudioCapture
            && !hasProcessTap
            && !hasSCKitCapture
    }
}
