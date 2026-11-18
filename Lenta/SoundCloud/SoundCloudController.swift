import Foundation
import WebKit

/// Данные трека из виджета SoundCloud
struct SCSound: Equatable {
    var id: Int
    var title: String
    var user: String
    var avatar: String
    var art: String
    var wave: String
    var dur: Double          // мс
    var permalink: String

    init?(_ any: Any?) {
        guard let d = any as? [String: Any] else { return nil }
        id = (d["id"] as? NSNumber)?.intValue ?? 0
        title = d["title"] as? String ?? ""
        user = d["user"] as? String ?? ""
        avatar = d["avatar"] as? String ?? ""
        art = d["art"] as? String ?? ""
        wave = d["wave"] as? String ?? ""
        dur = (d["dur"] as? NSNumber)?.doubleValue ?? 0
        permalink = d["link"] as? String ?? ""
    }

    var artwork: String { art.isEmpty ? avatar : art }
}

func art300(_ u: String) -> String { u.replacingOccurrences(of: "-large.", with: "-t300x300.") }

/// Встроенные плееры: виджет SoundCloud, плеер Spotify (официальный iFrame API), плеер Яндекс Музыки.
/// Один скрытый WKWebView, на каждый трек — своя страница. Звук не достаём, играет сам сервис.
final class WebPlayer: NSObject, ObservableObject {
    private var s: Services { .shared }

    @Published private(set) var trackID: String?
    @Published private(set) var source: TrackSource?
    @Published private(set) var ready = false
    @Published private(set) var playing = false
    @Published private(set) var waveNote = ""
    @Published var showWidget = false
    var userShown = false

    private(set) var pos = 0.0           // мс
    private(set) var dur = 0.0           // мс
    private var posAt = nowMs()
    let wave = WaveState()

    private var gen = 0
    private var everPlayed = false
    private var ended = false
    private var rewinding = false
    private var mediaFrame: WKFrameInfo?
    private var guardWork: DispatchWorkItem?

    let webView: WKWebView

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Self.mediaHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: cfg)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.customUserAgent = Importer.ua
        super.init()
        let h = WeakScriptHandler(self)
        ucc.add(h, name: "lc")
        ucc.add(h, name: "lcm")
    }

    func nowPos() -> Double { playing ? pos + (nowMs() - posAt) : pos }

    // MARK: - Загрузка трека

    func load(_ t: LTrack) {
        gen += 1
        trackID = t.id
        source = t.source
        ready = false; playing = false; everPlayed = false; ended = false
        pos = 0; dur = t.duration * 1000; posAt = nowMs()
        mediaFrame = nil
        guardWork?.cancel()
        wave.reset(failed: t.source != .soundcloud)
        updateNote()
        if !userShown { showWidget = false }

        let html: String, base: String
        switch t.source {
        case .soundcloud:
            html = scPage(t.ref); base = "https://led-lenta.vercel.app/"
        case .spotify:
            html = spotifyPage(t.ref); base = "https://open.spotify.com/"
        case .yandex:
            html = yandexPage(t.ref); base = "https://music.yandex.ru/"
        case .file:
            return
        }
        AudioSessionManager.activate()
        webView.loadHTMLString(html, baseURL: URL(string: base))

        // не дали включить звук — показываем сам плеер, пусть нажмут play в нём
        let g = gen
        let w = DispatchWorkItem { [weak self] in
            guard let self, g == self.gen, !self.playing else { return }
            if t.source == .yandex { self.ctl("play") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard g == self.gen, !self.playing else { return }
                self.showWidget = true
                self.s.app.showToast("Нажми play во встроенном плеере \(t.source.title)")
            }
        }
        guardWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    func stop() {
        gen += 1
        guardWork?.cancel()
        trackID = nil; source = nil; ready = false; playing = false
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        showWidget = false
    }

    func toggle() { playing ? pause() : resume() }

    func pause() {
        guard trackID != nil else { return }
        ctl("pause")
        if source == .yandex { setPlaying(false) }
    }

    func resume() {
        guard trackID != nil else { return }
        AudioSessionManager.activate()
        ctl("play")
    }

    func seek(_ seconds: Double) {
        let ms = max(0, seconds * 1000)
        ctl("seek", ms)
        pos = ms; posAt = nowMs()
    }

    func restart() {
        ended = false
        ctl("restart")
        pos = 0; posAt = nowMs()
    }

    private func ctl(_ cmd: String, _ arg: Double = 0) {
        if source == .yandex {
            guard let f = mediaFrame else { return }
            let ms = cmd == "seek" ? arg / 1000 : arg
            webView.callAsyncJavaScript("if (window.__lcCtl) window.__lcCtl(cmd, arg);",
                                        arguments: ["cmd": cmd, "arg": ms], in: f, in: .page, completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.lc && lc.\(cmd)(\(Int(arg)))", completionHandler: nil)
        }
    }

    private func setPlaying(_ on: Bool) {
        guard playing != on else { return }
        pos = nowPos(); posAt = nowMs()
        playing = on
        if on {
            everPlayed = true
            guardWork?.cancel()
            if showWidget && !userShown && source != .yandex { showWidget = false }
        }
        s.player.changed()
    }

    private func finished() {
        guard !ended else { return }
        ended = true
        playing = false
        s.player.trackEnded()
    }

    private func updateNote() {
        switch source {
        case .spotify, .yandex:
            waveNote = "\(source!.title) не даёт форму волны: лента мигает в ровном ритме. Для точной подсветки включи «Микрофон»."
        default:
            waveNote = (!wave.ready && wave.failed && source == .soundcloud)
                ? "Форма волны недоступна, лента мигает в ритм 120 BPM. Для точной подсветки включи «Микрофон»." : ""
        }
    }

    // MARK: - События

    fileprivate func handle(_ message: WKScriptMessage) {
        if message.name == "lcm" { handleMedia(message); return }
        guard let m = message.body as? [String: Any],
              let g = (m["g"] as? NSNumber)?.intValue, g == gen,
              let type = m["t"] as? String else { return }
        let d = m["d"]
        switch type {
        case "ready":
            ready = true
        case "play":
            setPlaying(true)
        case "pause":
            setPlaying(false)
        case "finish":
            finished()
        case "progress":
            guard let p = (d as? NSNumber)?.doubleValue else { return }
            pos = p; posAt = nowMs()
            if s.player.repeatMode == .one && dur > 2000 && pos >= dur - 700 && !rewinding {
                rewinding = true
                ctl("seek", 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.rewinding = false }
            }
        case "duration":
            if let v = (d as? NSNumber)?.doubleValue, v > 0 { dur = v }
            s.player.changed()
        case "current":
            guard let snd = SCSound(d), let id = trackID else { return }
            if snd.dur > 0 { dur = snd.dur }
            s.library.update(id) { t in
                if t.art.isEmpty && !snd.artwork.isEmpty { t.art = art300(snd.artwork) }
                if t.duration == 0 && snd.dur > 0 { t.duration = snd.dur / 1000 }
            }
            loadWave(snd)
            s.player.changed()
        case "state":
            // Spotify: playback_update
            guard let st = d as? [String: Any] else { return }
            let paused = (st["paused"] as? Bool) ?? true
            let p = (st["pos"] as? NSNumber)?.doubleValue ?? 0
            let du = (st["dur"] as? NSNumber)?.doubleValue ?? 0
            if du > 0 { dur = du }
            pos = p; posAt = nowMs()
            if !paused { ended = false }
            setPlaying(!paused)
            if paused && everPlayed && du > 0 && p >= du - 900 { finished() }
        case "error":
            s.app.showToast("\(source?.title ?? "Сервис") не открыл трек")
        default:
            break
        }
    }

    /// Плеер Яндекса: события звука из его страницы
    private func handleMedia(_ message: WKScriptMessage) {
        guard source == .yandex, let m = message.body as? [String: Any], let type = m["t"] as? String else { return }
        if !message.frameInfo.isMainFrame { mediaFrame = message.frameInfo }
        if type == "hook" {
            if !ready { ready = true; ctl("play") }
            return
        }
        guard type == "m", let d = m["d"] as? [String: Any] else { return }
        let ev = d["ev"] as? String ?? ""
        let paused = (d["paused"] as? Bool) ?? true
        let p = ((d["pos"] as? NSNumber)?.doubleValue ?? 0) * 1000
        let du = ((d["dur"] as? NSNumber)?.doubleValue ?? 0) * 1000
        if du > 0 { dur = du }
        pos = p; posAt = nowMs()
        if ev == "ended" { finished(); return }
        if !paused { ended = false }
        setPlaying(!paused)
    }

    private func loadWave(_ snd: SCSound) {
        let key = snd.id != 0 ? String(snd.id) : snd.wave
        guard wave.key != key else { return }
        guard !snd.wave.isEmpty else { wave.reset(failed: true); updateNote(); return }
        wave.reset()
        wave.key = key
        let durMs = snd.dur > 0 ? snd.dur : dur
        let url = snd.wave
        Task {
            let r = await WaveformLoader.load(waveURL: url, durationMs: durMs)
            await MainActor.run {
                guard self.wave.key == key else { return }
                if let r {
                    self.wave.n = r.n; self.wave.onset = r.onset; self.wave.tempo = r.tempo; self.wave.ready = true
                } else {
                    self.wave.failed = true
                }
                self.updateNote()
                self.s.light.waveChanged()
            }
        }
    }

    // MARK: - Страницы

    private func post() -> String {
        "var G = \(gen); function post(t, d) { try { webkit.messageHandlers.lc.postMessage({ g: G, t: t, d: d === undefined ? null : d }); } catch (e) {} }"
    }

    private func scPage(_ permalink: String) -> String {
        let enc = permalink.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? permalink
        let opts = "auto_play=false&visual=false&show_comments=false&show_reposts=false&hide_related=true&show_teaser=false&buying=false&sharing=false&download=false"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
        <script src="https://w.soundcloud.com/player/api.js"></script></head><body>
        <iframe id="f" allow="autoplay; encrypted-media" src="https://w.soundcloud.com/player/?url=\(enc)&\(opts)"></iframe>
        <script>
        (function () {
          \(post())
          function slim(s) {
            if (!s) return null;
            return { id: s.id || 0, title: s.title || '', user: (s.user && s.user.username) || '',
                     avatar: (s.user && s.user.avatar_url) || '', art: s.artwork_url || '',
                     wave: s.waveform_url || '', dur: s.duration || 0, link: s.permalink_url || '' };
          }
          var w = SC.Widget(document.getElementById('f')), E = SC.Widget.Events;
          w.bind(E.READY, function () { post('ready'); w.play(); });
          w.bind(E.PLAY, function () {
            post('play');
            w.getCurrentSound(function (s) { post('current', slim(s)); });
            w.getDuration(function (d) { post('duration', d); });
          });
          w.bind(E.PAUSE, function () { post('pause'); });
          w.bind(E.FINISH, function () { post('finish'); });
          w.bind(E.PLAY_PROGRESS, function (d) { post('progress', d.currentPosition); });
          w.bind(E.ERROR, function () { post('error'); });
          window.lc = {
            play: function () { w.play(); },
            pause: function () { w.pause(); },
            seek: function (ms) { w.seekTo(ms); },
            restart: function () { w.seekTo(0); w.play(); }
          };
        })();
        </script></body></html>
        """
    }

    private func spotifyPage(_ uri: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:#000}</style></head><body>
        <div id="e"></div>
        <script>
        \(post())
        window.onSpotifyIframeApiReady = function (API) {
          API.createController(document.getElementById('e'), { uri: '\(uri)', width: '100%', height: 152 }, function (c) {
            window.ctl = c;
            c.addListener('ready', function () { post('ready'); c.play(); });
            c.addListener('playback_update', function (e) {
              var d = e.data || {};
              post('state', { paused: !!d.isPaused, pos: d.position || 0, dur: d.duration || 0 });
            });
          });
        };
        window.lc = {
          play: function () { if (window.ctl) window.ctl.resume(); },
          pause: function () { if (window.ctl) window.ctl.pause(); },
          seek: function (ms) { if (window.ctl) window.ctl.seek(ms / 1000); },
          restart: function () { if (window.ctl) { window.ctl.seek(0); window.ctl.resume(); } }
        };
        </script>
        <script src="https://open.spotify.com/embed/iframe-api/v1" async></script>
        </body></html>
        """
    }

    private func yandexPage(_ ref: String) -> String {
        let p = ref.split(separator: ":").map(String.init)
        let track = p.first ?? "", album = p.count > 1 ? p[1] : ""
        let src = album.isEmpty ? "https://music.yandex.ru/iframe/track/\(track)" : "https://music.yandex.ru/iframe/track/\(track)/\(album)"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head><body>
        <iframe id="f" allow="autoplay; encrypted-media" src="\(src)"></iframe>
        <script>\(post()) document.getElementById('f').onload = function () { post('ready'); };</script>
        </body></html>
        """
    }

    /// Во все кадры: следим за элементом звука и даём им управлять (нужно для плеера Яндекса)
    private static let mediaHook = """
    (function () {
      if (window.__lcHook || !/yandex/.test(location.host)) return;
      window.__lcHook = 1;
      function post(t, d) { try { webkit.messageHandlers.lcm.postMessage({ t: t, d: d }); } catch (e) {} }
      var cur = null;
      function hook(el) {
        cur = el;
        if (el.__lc) return;
        el.__lc = 1;
        ['play', 'playing', 'pause', 'ended', 'timeupdate', 'durationchange'].forEach(function (ev) {
          el.addEventListener(ev, function () {
            cur = el;
            post('m', { ev: ev, paused: el.paused, pos: el.currentTime || 0, dur: isFinite(el.duration) ? el.duration : 0 });
          });
        });
      }
      var orig = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () { hook(this); return orig.apply(this, arguments); };
      document.addEventListener('play', function (e) { if (e.target && e.target.tagName) hook(e.target); }, true);
      window.__lcCtl = function (cmd, arg) {
        if (!cur) {
          if (cmd === 'play' || cmd === 'restart') {
            var b = document.querySelector('button[aria-label*="Воспроизв"], button[aria-label*="Play"], button[aria-label*="play"], [class*="play"] button, button[class*="play"]');
            if (b) b.click();
          }
          return;
        }
        if (cmd === 'play') cur.play();
        else if (cmd === 'pause') cur.pause();
        else if (cmd === 'seek') cur.currentTime = arg;
        else if (cmd === 'restart') { cur.currentTime = 0; cur.play(); }
      };
      if (window.top !== window) post('hook', location.host);
    })();
    """
}

/// WKUserContentController держит обработчик сильно — разрываем цикл
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebPlayer?
    init(_ t: WebPlayer) { target = t }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message)
    }
}
