import WebKit

@MainActor
enum MaomaoWebCompatibility {
    // WKWebView's default UA omits Safari/Version. Discord then selects WebM
    // nameplates and its WebM spinner instead of its Safari animation assets.
    // WebKit can decode VP9 without preserving its alpha channel. Advertise a
    // Safari compatibility baseline supported by our macOS 26.6+ deployment
    // target, retaining WebKit's own platform/engine UA prefix. This is not the
    // installed Safari version. Do not derive it from the macOS version.
    static let mediaCompatibilityIdentity = "Version/26.0 Safari/605.1.15"

    static func configure(_ configuration: WKWebViewConfiguration,
                          editionID: String? = EditionIdentity.current?.id) {
        guard editionID == "maomao" else { return }
        configuration.applicationNameForUserAgent = mediaCompatibilityIdentity
    }
}
