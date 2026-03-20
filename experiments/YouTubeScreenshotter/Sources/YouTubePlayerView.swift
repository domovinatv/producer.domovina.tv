import SwiftUI
import WebKit

// MARK: - YouTube Player (loads actual YouTube page, not embed)

/// Loads the real YouTube watch page in WKWebView and injects JS to control the player.
/// This bypasses embedding restrictions since we're loading youtube.com directly.
struct YouTubePlayerView: NSViewRepresentable {
    let videoId: String
    @Binding var seekToSeconds: Double?
    @Binding var captureRequest: UUID?
    let onCapture: (NSImage?) -> Void
    let onReady: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Inject our controller script after page loads
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "screenshotter")
        config.userContentController = userController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView

        // Load actual YouTube page
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Handle seek requests
        if let seconds = seekToSeconds {
            DispatchQueue.main.async { self.seekToSeconds = nil }
            // Use YouTube's native player API on the page
            let js = """
            (function() {
                var video = document.querySelector('video');
                if (video) {
                    video.currentTime = \(seconds);
                    video.pause();
                }
                // Also try YouTube's player API
                var player = document.getElementById('movie_player');
                if (player && player.seekTo) {
                    player.seekTo(\(seconds), true);
                    setTimeout(function() { player.pauseVideo(); }, 500);
                }
            })();
            """
            webView.evaluateJavaScript(js)
        }

        // Handle capture requests
        if let requestId = captureRequest, requestId != context.coordinator.lastCaptureId {
            context.coordinator.lastCaptureId = requestId
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.takeSnapshot(webView: webView)
            }
        }
    }

    private func takeSnapshot(webView: WKWebView) {
        // First, hide YouTube UI chrome via JS
        let hideUI = """
        (function() {
            // Hide controls, header, sidebar, comments
            var selectors = [
                '.ytp-chrome-bottom', '.ytp-chrome-top', '.ytp-gradient-bottom',
                '.ytp-gradient-top', '.ytp-pause-overlay', '.ytp-watermark',
                '#masthead-container', '#secondary', '#comments', '#related',
                '#below', '#info', '#meta', '#above-the-fold',
                'ytd-watch-metadata', '#panels'
            ];
            selectors.forEach(function(sel) {
                document.querySelectorAll(sel).forEach(function(el) {
                    el.style.display = 'none';
                });
            });

            // Make video fill the page
            var video = document.querySelector('video');
            if (video) {
                video.style.objectFit = 'contain';
            }

            // Try to go fullscreen on the player
            var player = document.querySelector('#movie_player');
            if (player) {
                player.style.position = 'fixed';
                player.style.top = '0';
                player.style.left = '0';
                player.style.width = '100vw';
                player.style.height = '100vh';
                player.style.zIndex = '99999';
                player.style.background = '#000';
            }
        })();
        """
        webView.evaluateJavaScript(hideUI) { _, _ in
            // Wait for UI changes to render
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let config = WKSnapshotConfiguration()
                // Capture at 2x native resolution for Retina (3840px on a 1920pt-wide view)
                let scaledWidth = webView.bounds.width * (webView.window?.backingScaleFactor ?? 2.0)
                config.snapshotWidth = NSNumber(value: Int(scaledWidth))

                webView.takeSnapshot(with: config) { image, error in
                    // Restore UI
                    let restoreUI = """
                    (function() {
                        var selectors = [
                            '.ytp-chrome-bottom', '.ytp-chrome-top', '.ytp-gradient-bottom',
                            '.ytp-gradient-top', '.ytp-watermark',
                            '#masthead-container'
                        ];
                        selectors.forEach(function(sel) {
                            document.querySelectorAll(sel).forEach(function(el) {
                                el.style.display = '';
                            });
                        });
                        var player = document.querySelector('#movie_player');
                        if (player) {
                            player.style.position = '';
                            player.style.top = '';
                            player.style.left = '';
                            player.style.width = '';
                            player.style.height = '';
                            player.style.zIndex = '';
                        }
                    })();
                    """
                    webView.evaluateJavaScript(restoreUI)

                    DispatchQueue.main.async {
                        self.onCapture(image)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastCaptureId: UUID?
        let onReady: () -> Void
        var pageLoaded = false

        init(onReady: @escaping () -> Void) {
            self.onReady = onReady
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !pageLoaded else { return }
            pageLoaded = true

            // Wait for YouTube player to initialize, then notify ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                // Try to dismiss cookie consent
                let dismissCookies = """
                (function() {
                    // Click accept cookies if present
                    var buttons = document.querySelectorAll('button');
                    buttons.forEach(function(btn) {
                        if (btn.textContent.includes('Accept') || btn.textContent.includes('Prihvati') ||
                            btn.textContent.includes('I agree') || btn.textContent.includes('Slažem se')) {
                            btn.click();
                        }
                    });
                    // Also try tp.consent forms
                    var form = document.querySelector('form[action*="consent"]');
                    if (form) {
                        var submitBtn = form.querySelector('button');
                        if (submitBtn) submitBtn.click();
                    }
                })();
                """
                webView.evaluateJavaScript(dismissCookies) { _, _ in
                    // After cookies dismissed, maximize the player
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.maximizePlayer(webView)
                    }
                }
            }
        }

        func maximizePlayer(_ webView: WKWebView) {
            let js = """
            (function() {
                // 1. Hide everything except the video player
                var hideSelectors = [
                    '#masthead-container',      // Top navigation bar
                    '#secondary',               // Sidebar / recommendations
                    '#comments',                // Comments section
                    '#related',                 // Related videos
                    '#below',                   // Below-fold content
                    '#info',                    // Video info
                    '#meta',                    // Video metadata
                    '#above-the-fold',          // Above fold container
                    'ytd-watch-metadata',       // Watch metadata
                    '#panels',                  // Side panels
                    '#chat',                    // Live chat
                    'ytd-miniplayer',           // Mini player
                    '#guide',                   // Left sidebar guide
                    '#guide-button',            // Hamburger menu
                    'tp-yt-app-drawer',         // App drawer
                    '#description',             // Video description
                    '#actions',                 // Like/share buttons
                    '#owner',                   // Channel info
                    '#ticket-shelf',            // Ticket shelf
                    '#merch-shelf',             // Merch shelf
                    '.ytd-watch-flexy #below',  // Below content
                    '#page-manager > :not(ytd-watch-flexy)', // Non-watch pages
                    'ytd-popup-container',      // Popups
                    'iron-overlay-backdrop',    // Overlay backdrops
                ];
                hideSelectors.forEach(function(sel) {
                    document.querySelectorAll(sel).forEach(function(el) {
                        el.style.display = 'none';
                    });
                });

                // 2. Make the player fill the entire viewport
                var player = document.querySelector('#movie_player');
                if (player) {
                    player.style.position = 'fixed';
                    player.style.top = '0';
                    player.style.left = '0';
                    player.style.width = '100vw';
                    player.style.height = '100vh';
                    player.style.zIndex = '99999';
                    player.style.background = '#000';
                }

                // Also make the video element fill
                var video = document.querySelector('video');
                if (video) {
                    video.style.width = '100%';
                    video.style.height = '100%';
                    video.style.objectFit = 'contain';
                }

                // Make the player container fill too
                var container = document.querySelector('#player-container-outer');
                if (container) {
                    container.style.position = 'fixed';
                    container.style.top = '0';
                    container.style.left = '0';
                    container.style.width = '100vw';
                    container.style.height = '100vh';
                    container.style.zIndex = '99998';
                }
                var inner = document.querySelector('#player-container-inner');
                if (inner) {
                    inner.style.width = '100vw';
                    inner.style.height = '100vh';
                    inner.style.maxWidth = 'none';
                }

                // Hide player chrome (controls overlay)
                var chromeSelectors = [
                    '.ytp-chrome-top',
                    '.ytp-gradient-top',
                    '.ytp-pause-overlay',
                    '.ytp-watermark',
                ];
                chromeSelectors.forEach(function(sel) {
                    document.querySelectorAll(sel).forEach(function(el) {
                        el.style.display = 'none';
                    });
                });

                // 3. Set body/html to overflow hidden
                document.body.style.overflow = 'hidden';
                document.documentElement.style.overflow = 'hidden';

                // 4. Auto-select highest quality via YouTube player API
                var ytPlayer = document.getElementById('movie_player');
                if (ytPlayer && ytPlayer.setPlaybackQualityRange) {
                    // Try to set to highest available
                    var qualities = ytPlayer.getAvailableQualityLevels ? ytPlayer.getAvailableQualityLevels() : [];
                    if (qualities.length > 0) {
                        var best = qualities[0]; // First is highest
                        ytPlayer.setPlaybackQualityRange(best, best);
                    }
                }

                return 'maximized';
            })();
            """;
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("Maximize error: \(error)")
                }
                // Signal ready after maximizing
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.onReady()
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // For future JS→Swift messaging
        }

        // Allow all navigation within YouTube
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}
