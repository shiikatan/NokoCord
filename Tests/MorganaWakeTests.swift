import AppKit
import WebKit
import XCTest
@testable import NokoCordCore

@MainActor
final class MorganaWakeTests: XCTestCase {
    private let fixtureOrigin = "https://fixture.invalid"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-MorganaWakeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeView(runtime: TanRuntime) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        runtime.prepare(configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        runtime.attach(view)
        return view
    }

    private func loadFixture(_ view: WKWebView, runtime: TanRuntime) async throws {
        runtime.documentNavigationStarted()
        view.loadHTMLString("<html><head></head><body><main id='fixture'>Fixture</main></body></html>",
                            baseURL: URL(string: fixtureOrigin + "/app")!)
        for _ in 0..<100 {
            if let ready = try? await view.evaluateJavaScript("document.readyState === 'complete' && document.getElementById('fixture') !== null") as? Bool,
               ready {
                runtime.pageDidLoad()
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Fixture page did not finish loading")
        runtime.pageDidLoad()
    }

    private func waitForCount(_ view: WKWebView, _ expression: String, expected: Int) async throws -> Int {
        var last = -1
        for _ in 0..<100 {
            if let result = try? await view.evaluateJavaScript(expression) as? Int {
                last = result
                if result == expected { return result }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return last
    }

    private func waitForTrue(_ view: WKWebView, _ expression: String) async throws -> Bool {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(expression) as? Bool) == true { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testMorganaWakeRestoresReplacedAudioHooksWithoutWrappingAgain() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TanManager(root: root)
        let morgana = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.morgana" }))
        XCTAssertEqual(morgana.manifest.version, "1.1.1")
        XCTAssertEqual(morgana.manifest.target, .page)
        try manager.install(morgana)
        manager.setEnabled(morgana.id, true)

        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)

        let initialPingIntercepted = try await view.evaluateJavaScript("""
          (() => {
            const audio = new Audio('message1.mp3');
            return audio.src.startsWith('blob:') || audio.src.startsWith('data:audio/mpeg;base64,');
          })()
          """) as? Bool
        XCTAssertEqual(initialPingIntercepted, true, "Morgana should intercept the normal message1.mp3 Audio constructor")

        let initialOrdinaryAudioUnchanged = try await view.evaluateJavaScript("""
          (() => new Audio('ambient.ogg').getAttribute('src') === 'ambient.ogg')()
          """) as? Bool
        XCTAssertEqual(initialOrdinaryAudioUnchanged, true, "Ordinary Audio sources should pass through")

        let documentToken = UUID().uuidString
        _ = try await view.evaluateJavaScript("document.documentElement.setAttribute('data-morgana-document-token', '\(documentToken)')")

        _ = try await view.evaluateJavaScript("""
          window.__morganaAudioArgs = [];
          window.__discordAudio = function(source) {
            window.__morganaAudioArgs.push(source == null ? null : String(source));
            return document.createElement('audio');
          };
          window.Audio = window.__discordAudio;

          window.__morganaPlayCalls = [];
          window.__discordPlay = function() {
            window.__morganaPlayCalls.push(this.getAttribute('src') || '');
            return 'fixture-play';
          };
          HTMLMediaElement.prototype.play = window.__discordPlay;
          window.webpackChunkdiscord_app = [];
          """)

        runtime.didWake()
        let recovered = try await waitForTrue(view, """
          window.Audio !== window.__discordAudio &&
          HTMLMediaElement.prototype.play !== window.__discordPlay &&
          window.webpackChunkdiscord_app.push !== Array.prototype.push
          """)
        XCTAssertTrue(recovered, "Wake should reinstall Audio, play, and Webpack interception after Discord replaces them")

        _ = try await view.evaluateJavaScript("""
          window.__morganaAudioWrapper = window.Audio;
          window.__morganaPlayWrapper = HTMLMediaElement.prototype.play;
          window.__morganaPushWrapper = window.webpackChunkdiscord_app.push;
          true;
          """)
        _ = try await view.evaluateJavaScript("""
          try {
            new Audio('message1.mp3');
            new Audio('ambient.ogg');
          } catch (error) {
            window.__morganaConstructorError = String(error);
          }
          true;
          """)
        let constructorError = try await view.evaluateJavaScript("window.__morganaConstructorError || ''") as? String
        XCTAssertEqual(constructorError, "", "Recovered Audio constructors should remain callable")
        let replacedAudioResults = try await view.evaluateJavaScript("""
          window.__morganaAudioArgs.length === 2 &&
          (window.__morganaAudioArgs[0].startsWith('blob:') || window.__morganaAudioArgs[0].startsWith('data:audio/mpeg;base64,')) &&
          window.__morganaAudioArgs[1] === 'ambient.ogg'
          """) as? Bool
        XCTAssertEqual(replacedAudioResults, true, "Recovered Audio interception should replace message pings and preserve ordinary audio")

        let replacedPlayResults = try await view.evaluateJavaScript("""
          (() => {
            const ping = document.createElement('audio');
            ping.src = 'message2.mp3';
            const pingResult = ping.play();
            const ordinary = document.createElement('audio');
            ordinary.src = 'ambient.ogg';
            const ordinaryResult = ordinary.play();
            return pingResult === 'fixture-play' &&
              (ping.src.startsWith('blob:') || ping.src.startsWith('data:audio/mpeg;base64,')) &&
              ordinaryResult === 'fixture-play' && ordinary.getAttribute('src') === 'ambient.ogg' &&
              window.__morganaPlayCalls.length === 2;
          })()
          """) as? Bool
        XCTAssertEqual(replacedPlayResults, true, "Recovered play interception should rewrite notification sources only")

        let webpackResults = try await view.evaluateJavaScript("""
          (() => {
            const chunk = [[], {
              fixtureSoundContext: function(module) {
                module.exports = request => request === 'message1.mp3' ? '/assets/message1.mp3' : request;
              }
            }];
            window.webpackChunkdiscord_app.push(chunk);
            const module = {exports: null};
            chunk[1].fixtureSoundContext(module);
            const ping = module.exports('message1.mp3');
            const ordinary = module.exports('ambient.ogg');
            return (ping.startsWith('blob:') || ping.startsWith('data:audio/mpeg;base64,')) && ordinary === 'ambient.ogg';
          })()
          """) as? Bool
        XCTAssertEqual(webpackResults, true, "Recovered Webpack interception should rewrite message sound requests only")

        let tokenAfterFirstWake = try await view.evaluateJavaScript("document.documentElement.getAttribute('data-morgana-document-token')") as? String
        XCTAssertEqual(tokenAfterFirstWake, documentToken, "Wake recovery should keep the same fixture document loaded")

        _ = try await view.evaluateJavaScript("""
          window.__morganaRevokeCount = 0;
          window.__morganaNativeRevoke = URL.revokeObjectURL.bind(URL);
          URL.revokeObjectURL = function(url) {
            window.__morganaRevokeCount += 1;
            return window.__morganaNativeRevoke(url);
          };
          true;
          """)
        runtime.didWake()
        let revokeCount = try await waitForCount(view, "window.__morganaRevokeCount", expected: 1)
        XCTAssertEqual(revokeCount, 1, "Second wake should complete Morgana's resume path")

        let wrappersStable = try await view.evaluateJavaScript("""
          window.Audio === window.__morganaAudioWrapper &&
          HTMLMediaElement.prototype.play === window.__morganaPlayWrapper &&
          window.webpackChunkdiscord_app.push === window.__morganaPushWrapper
          """) as? Bool
        XCTAssertEqual(wrappersStable, true, "Repeated wake should retain the installed interception wrappers")

        let tokenAfterSecondWake = try await view.evaluateJavaScript("document.documentElement.getAttribute('data-morgana-document-token')") as? String
        XCTAssertEqual(tokenAfterSecondWake, documentToken, "Repeated wake should not reload the fixture document")
    }
}
