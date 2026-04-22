// AppGroup
//
// Single source of truth for the App Group identifier, compiled into
// every target that participates in cross-process storage — the main
// `Stir` app, `StirWidgets` (Home Screen + Live Activity), and
// `StirShareExtension` (Safari share sheet).
//
// The group must be registered in the Apple Developer portal against
// the same Team ID as each target (25H5DDPKAC), and its identifier
// must appear verbatim in each target's .entitlements file. See
// project.yml — `com.apple.security.application-groups`.

import Foundation

public enum AppGroup {
    public static let identifier = "group.com.scalinity.stir"
}
