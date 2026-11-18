import Foundation
import WebKit

struct SCSound: Equatable {
    var id: Int
    var title: String
    var user: String
    var avatar: String
    var art: String
    var wave: String
    var dur: Double          // мс

    init?(_ any: Any?) {
        guard let d = any as? [String: Any] else { return nil }
        id = (d["id"] as? NSNumber)?.intValue ?? 0
        title = d["title"] as? String ?? ""
        user = d["user"] as? String ?? ""
        avatar = d["avatar"] as? String ?? ""
        art = d["art"] as? String ?? ""
        wave = d["wave"] as? String ?? ""
        dur = (d["dur"] as? NSNumber)?.doubleValue ?? 0
    }

    var artwork: String { art.isEmpty ? avatar : art }
}

struct SCLibItem: Codable, Identifiable, Equatable {
    var url: String
    var title: String
    var art: String
    var id: String { url }
}

func art300(_ u: String) -> String { u.replacingOccurrences(of: "-large.", with: "-t300x300.") }

/// SoundCloud: официальный виджет в скрытом WKWebView + свой тёмный список и «Мои плейлисты».
/// Поток не достаём закрытыми ключами — играет сам виджет.
final class SoundCloudController: NSObject, ObservableObject {
    private var s: Services { .shared }

    @Published private(set) var lib: [SCLibItem] = Prefs.get("scLib", [SCLibItem]())
    @Published private(set) var url = ""
    @Published private(set) var title = ""
    @Published private(set) var cover = ""
    @Published private(set) var ready = false
    @Published private(set) var loaded = false
    @Published private(set) var playing = false
    @Published private(set) var sounds: [SCSound] = []
    @Published private(set) var index = -1
    @Published private(set) var loadFailed = false
    @Published private(set) var waveNote = ""
    @Published var showWidget = false
    var userShown = false

    private(set) var pos = 0.0           // мс
    private(set) var dur = 0.0           // мс
    private var posAt = nowMs()
    let wave = WaveState()

    private var autoplay = false
    private var gen = 0
    private var soundsTries = 0
    private var rewinding = false
    private var onIndexOnly: ((Int) -> Void)?
    private var guardWork: DispatchWorkItem?
    private var afterWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var loadWork: DispatchWorkItem?

    let webView: WKWebView

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: cfg)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        super.init()
        ucc.add(WeakScriptHandler(self), name: "sc")
    }

    var has: Bool { ready && !sounds.isEmpty }
    var currentSound: SCSound? { sounds.indices.contains(index) ? sounds[index] : nil }
    var artURLString: String {
        if let c = currentSound, !c.artwork.isEmpty { return art300(c.artwork) }
        return cover
    }

    /// Позиция сейчас (мс): между событиями PLAY_PROGRESS досчитываем сами
    func nowPos() -> Double { playing ? pos + (nowMs() - posAt) : pos }

    var subtitle: String {
        if !ready || (sounds.isEmpty && !loaded) {
            return loadFailed ? "Не загрузилось. Нажми на плейлист ещё раз" : "Загрузка…"
        }
        let n = sounds.count
        guard n > 0 else { return "Нет треков" }
        let total = sounds.reduce(0) { $0 + $1.dur }
        return "\(n) \(plural(n, "трек", "трека", "треков"))" + (total > 0 ? " · \(Int((total / 60000).rounded())) мин" : "")
    }

    // MARK: - Ссылки и «Мои плейлисты»

    /// Из поля ввода: полная ссылка, короткая on.soundcloud.com или текст «Поделиться» со ссылкой внутри
    func add(text raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var link = t
        if let r = t.range(of: #"https?://\S+"#, options: .regularExpression) { link = String(t[r]) }
        if link.range(of: #"^https?://on\.soundcloud\.com/"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let u = URL(string: link) {
            Task {
                let resolved = (try? await URLSession.shared.data(from: u))?.1.url?.absoluteString
                await MainActor.run {
                    if let resolved, resolved.contains("soundcloud.com") { self.openChecked(resolved) }
                    else { self.s.app.showToast("Короткая ссылка не открылась. Скопируй полную") }
                }
            }
            return
        }
        openChecked(link)
    }

    private func openChecked(_ link: String) {
        guard link.range(of: #"^https?://(www\.|m\.)?soundcloud\.com/.+"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            s.app.showToast("Нужна ссылка вида soundcloud.com/…")
            return
        }
        var u = String(link.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        u = u.replacingOccurrences(of: "//m.", with: "//")
        while u.hasSuffix("/") { u.removeLast() }
        open(u, autoplay: true)
    }

    private func slugTitle(_ url: String) -> String {
        guard let path = URL(string: url)?.path else { return "SoundCloud" }
        let parts = path.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0.range(of: #"^s-[A-Za-z0-9]+$"#, options: .regularExpression) == nil }
        let last = (parts.last ?? "SoundCloud").removingPercentEncoding ?? "SoundCloud"
        let t = last.replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return "SoundCloud" }
        return f.uppercased() + t.dropFirst()
    }

    @discardableResult
    private func saveToLib(_ url: String, title: String? = nil, art: String? = nil) -> SCLibItem {
        var i = lib.firstIndex { $0.url == url }
        if i == nil {
            lib.insert(SCLibItem(url: url, title: slugTitle(url), art: ""), at: 0)
            i = 0
        }
        let k = i!
        if let title, !title.isEmpty { lib[k].title = title }
        if let art, !art.isEmpty { lib[k].art = art }
        Prefs.set("scLib", lib)
        return lib[k]
    }

    func removeFromLib(_ url: String) {
        lib.removeAll { $0.url == url }
        Prefs.set("scLib", lib)
    }

    private func fetchMeta(_ url: String) async -> (String, String)? {
        guard let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let u = URL(string: "https://soundcloud.com/oembed?format=json&url=" + enc),
              let res = try? await URLSession.shared.data(from: u),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any] else { return nil }
        return (j["title"] as? String ?? "", j["thumbnail_url"] as? String ?? "")
    }

    // MARK: - Открыть плейлист

    func open(_ url: String, autoplay: Bool) {
        // тот же плейлист: просто играем, без перезагрузки
        if url == self.url && ready && !sounds.isEmpty {
            if autoplay && !playing { toggle() }
            return
        }
        if ready && playing { js("lc.pause()") }
        [guardWork, afterWork, retryWork, loadWork].forEach { $0?.cancel() }
        gen += 1
        self.url = url
        ready = false; loaded = false; playing = false; loadFailed = false
        pos = 0; dur = 0; sounds = []; index = -1
        self.autoplay = autoplay
        wave.reset()
        updateWaveNote()
        let it = saveToLib(url)
        title = it.title
        cover = it.art
        Task {
            guard let m = await self.fetchMeta(url) else { return }
            await MainActor.run {
                let upd = self.saveToLib(url, title: m.0, art: m.1)
                if self.url == url { self.title = upd.title; self.cover = upd.art; self.s.player.changed() }
            }
        }
        // свежий плеер на каждый плейлист: старый после load() не всегда снова сообщает READY
        webView.loadHTMLString(html(url, gen: gen), baseURL: URL(string: "https://led-lenta.vercel.app/"))
        let g = gen
        let w = DispatchWorkItem { [weak self] in
            guard let self, g == self.gen, !self.ready else { return }
            self.loadFailed = true
            self.s.app.showToast("SoundCloud не ответил. Проверь интернет и нажми на плейлист ещё раз")
        }
        loadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
        s.player.changed()
    }

    // MARK: - Управление

    func play(_ i: Int) {
        guard ready, !sounds.isEmpty else { return }
        s.player.setActive(.sc)
        AudioSessionManager.activate()
        js("lc.skip(\(i)); lc.play()")
        guardWork?.cancel()
        let g = gen
        // медленная сеть может стартовать несколько секунд; считаем, что не дали играть, только если правда на паузе
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.playing, g == self.gen else { return }
            self.js("lc.isPaused()")
        }
        guardWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: w)
    }

    func toggle() {
        guard ready, !sounds.isEmpty else { return }
        if index < 0 { play(s.player.shuffle ? rnd(sounds.count, not: -1) : 0); return }
        if playing { js("lc.pause()") }
        else {
            s.player.setActive(.sc)
            AudioSessionManager.activate()
            js("lc.play()")
        }
    }

    func pause() { if ready && playing { js("lc.pause()") } }

    func next() {
        if let i = s.player.pickNext(index, sounds.count, auto: false) { play(i) }
    }

    func prev() {
        guard !sounds.isEmpty else { return }
        if pos > 3000 { seek(0); return }
        play(s.player.shuffle ? rnd(sounds.count, not: index) : (index - 1 + sounds.count) % sounds.count)
    }

    func seek(_ seconds: Double) {
        let ms = max(0, seconds * 1000)
        js("lc.seek(\(Int(ms)))")
        pos = ms; posAt = nowMs()
        s.player.refreshNowPlaying()
    }

    func shufflePlay() {
        if !s.player.shuffle { s.player.toggleShuffle() }
        play(rnd(sounds.count, not: index))
    }

    func tapTrack(_ i: Int) { i == index ? toggle() : play(i) }

    private func js(_ code: String) {
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    // MARK: - События виджета

    fileprivate func handle(_ body: Any) {
        guard let m = body as? [String: Any],
              let g = (m["g"] as? NSNumber)?.intValue, g == gen,
              let type = m["t"] as? String else { return }   // события от уже заменённого плеера пропускаем
        let d = m["d"]
        switch type {
        case "ready":
            guard !ready else { return }
            ready = true
            loadWork?.cancel()
            loadSounds(0)
        case "sounds":
            gotSounds(((d as? [Any]) ?? []).compactMap { SCSound($0) })
        case "play":
            guard ready else { return }
            playing = true
            guardWork?.cancel(); afterWork?.cancel()
            if showWidget && !userShown { showWidget = false }
            s.player.setActive(.sc)
            s.player.changed()
        case "index":
            guard let i = (d as? NSNumber)?.intValue else { return }
            index = i
            s.player.changed()
        case "current":
            guard let c = d as? [String: Any], let i = (c["i"] as? NSNumber)?.intValue, i == index,
                  let snd = SCSound(c["s"]) else { return }
            if !snd.title.isEmpty, sounds.indices.contains(i),
               sounds[i].title.isEmpty || sounds[i].wave.isEmpty {
                sounds[i] = snd
                s.player.changed()
            }
            loadWave(!snd.wave.isEmpty ? snd : (sounds.indices.contains(i) ? sounds[i] : snd))
        case "duration":
            dur = (d as? NSNumber)?.doubleValue ?? dur
            s.player.changed()
        case "pause":
            guard ready else { return }
            pos = nowPos(); posAt = nowMs()
            playing = false
            s.player.changed()
        case "finish":
            guard ready else { return }
            playing = false
            finished()
        case "progress":
            guard ready, let p = (d as? NSNumber)?.doubleValue else { return }
            pos = p; posAt = nowMs()
            // повтор трека: перематываем перед самым концом, чтобы виджет не ушёл дальше
            if s.player.repeatMode == .one && dur > 2000 && pos >= dur - 700 && !rewinding {
                rewinding = true
                js("lc.seek(0)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.rewinding = false }
            }
        case "paused":
            if (d as? Bool) == true && !playing {
                showWidget = true
                s.app.showToast("Звук не включился. Нажми play в плеере SoundCloud")
            }
        case "indexOnly":
            if let i = (d as? NSNumber)?.intValue { onIndexOnly?(i); onIndexOnly = nil }
        case "error":
            s.app.showToast("SoundCloud не открыл ссылку. Плейлист должен быть открытым или по секретной ссылке")
        default:
            break
        }
    }

    /// Виджет заполняет плейлист постепенно: сначала ничего, потом id, потом данные треков
    private func loadSounds(_ tries: Int) {
        soundsTries = tries
        js("lc.sounds()")
    }

    private func retrySounds(after sec: Double) {
        retryWork?.cancel()
        let g = gen, next = soundsTries + 1
        let w = DispatchWorkItem { [weak self] in
            guard let self, g == self.gen else { return }
            self.loadSounds(next)
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }

    private func gotSounds(_ list: [SCSound]) {
        if list.isEmpty && soundsTries < 24 { retrySounds(after: 0.5); return }
        let old = sounds
        sounds = list.enumerated().map { i, snd in
            (snd.title.isEmpty && old.indices.contains(i) && !old[i].title.isEmpty) ? old[i] : snd
        }
        loaded = true
        if autoplay && !sounds.isEmpty {
            autoplay = false
            play(s.player.shuffle ? rnd(sounds.count, not: -1) : 0)
        }
        if let it = lib.first(where: { $0.url == url }), it.art.isEmpty, let f = sounds.first, !f.artwork.isEmpty {
            saveToLib(url, art: art300(f.artwork))
            if cover.isEmpty { cover = art300(f.artwork) }
        }
        if let c = currentSound, wave.key == nil, !wave.ready { loadWave(c) }
        if sounds.contains(where: { $0.title.isEmpty }) && soundsTries < 24 { retrySounds(after: 1.5) }
        s.player.changed()
    }

    private func finished() {
        guard let i = s.player.pickNext(index, sounds.count, auto: true) else {
            s.player.changed()
            return
        }
        afterWork?.cancel()
        if i == index {
            // виджет сам перескакивает на следующий трек — возвращаем тот же
            let keep = index
            js("lc.skip(\(keep)); lc.seek(0); lc.play()")
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.onIndexOnly = { now in if now != keep { self.js("lc.skip(\(keep)); lc.play()") } }
                self.js("lc.index()")
            }
            afterWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
            return
        }
        // плейлист в виджете идёт дальше сам; вмешиваемся для случайного порядка, круга или если встал
        if s.player.shuffle || i != index + 1 { play(i) }
        else {
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.playing else { return }
                self.play(i)
            }
            afterWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
        s.player.changed()
    }

    // MARK: - Форма волны

    private func loadWave(_ snd: SCSound) {
        let key = snd.id != 0 ? String(snd.id) : (!snd.wave.isEmpty ? snd.wave : snd.title)
        guard wave.key != key else { return }
        // данных пока нет: временно ровный пульс, но позже с полными данными попробуем снова
        guard !snd.wave.isEmpty else { wave.reset(failed: true); updateWaveNote(); return }
        wave.reset()
        wave.key = key
        let durMs = snd.dur > 0 ? snd.dur : dur
        let waveURL = snd.wave
        Task {
            let r = await WaveformLoader.load(waveURL: waveURL, durationMs: durMs)
            await MainActor.run {
                guard self.wave.key == key else { return }
                if let r {
                    self.wave.n = r.n
                    self.wave.onset = r.onset
                    self.wave.tempo = r.tempo
                    self.wave.ready = true
                } else {
                    self.wave.failed = true
                }
                self.updateWaveNote()
                self.s.light.waveChanged()
            }
        }
    }

    private func updateWaveNote() {
        waveNote = (!wave.ready && wave.failed)
            ? "Форма волны недоступна, лента мигает в ритм 120 BPM. Для точной подсветки включи микрофон."
            : ""
    }

    // MARK: - Страница с виджетом

    private func html(_ url: String, gen: Int) -> String {
        let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        let opts = "auto_play=false&visual=false&show_comments=false&show_reposts=false&hide_related=true&show_teaser=false&buying=false&sharing=false&download=false"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
        <script src="https://w.soundcloud.com/player/api.js"></script></head><body>
        <iframe id="f" allow="autoplay; encrypted-media" src="https://w.soundcloud.com/player/?url=\(enc)&\(opts)"></iframe>
        <script>
        (function () {
          var G = \(gen);
          function post(t, d) { try { webkit.messageHandlers.sc.postMessage({ g: G, t: t, d: d === undefined ? null : d }); } catch (e) {} }
          function slim(s) {
            if (!s) return null;
            return { id: s.id || 0, title: s.title || '', user: (s.user && s.user.username) || '',
                     avatar: (s.user && s.user.avatar_url) || '', art: s.artwork_url || '',
                     wave: s.waveform_url || '', dur: s.duration || 0 };
          }
          var w = SC.Widget(document.getElementById('f')), E = SC.Widget.Events;
          w.bind(E.READY, function () { post('ready'); });
          w.bind(E.PLAY, function () {
            post('play');
            w.getCurrentSoundIndex(function (i) {
              post('index', i);
              w.getCurrentSound(function (s) { post('current', { i: i, s: slim(s) }); });
            });
            w.getDuration(function (d) { post('duration', d); });
          });
          w.bind(E.PAUSE, function () { post('pause'); });
          w.bind(E.FINISH, function () { post('finish'); });
          w.bind(E.PLAY_PROGRESS, function (d) { post('progress', d.currentPosition); });
          w.bind(E.ERROR, function () { post('error'); });
          window.lc = {
            sounds: function () { w.getSounds(function (l) { post('sounds', (l || []).map(slim)); }); },
            play: function () { w.play(); },
            pause: function () { w.pause(); },
            skip: function (i) { w.skip(i); },
            seek: function (ms) { w.seekTo(ms); },
            isPaused: function () { w.isPaused(function (p) { post('paused', p); }); },
            index: function () { w.getCurrentSoundIndex(function (i) { post('indexOnly', i); }); }
          };
        })();
        </script></body></html>
        """
    }
}

/// WKUserContentController держит обработчик сильно — разрываем цикл
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: SoundCloudController?
    init(_ t: SoundCloudController) { target = t }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}
