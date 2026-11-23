import Foundation
import WebKit
import UIKit

struct ImportError: Error { let message: String }

struct ImportResult {
    var tracks: [LTrack]
    /// Есть — значит это плейлист или альбом
    var playlistName: String?
    var art: String = ""
    var origin: String = ""
}

/// Ссылка → треки. SoundCloud — через официальный виджет, Spotify — через публичную страницу встраивания,
/// Яндекс — через открытые методы api.music.yandex.net. Закрытые ключи не используем.
enum Importer {

    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func detect(_ text: String) -> TrackSource? {
        let t = text.lowercased()
        if t.contains("soundcloud.com") || t.contains("on.soundcloud") { return .soundcloud }
        if t.contains("spotify.com") || t.contains("spotify:") || t.contains("spotify.link") { return .spotify }
        if t.contains("music.yandex") || t.contains("yandex.ru/music") { return .yandex }
        return nil
    }

    static func load(_ text: String) async -> Result<ImportResult, ImportError> {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = link.range(of: #"(https?://|spotify:)\S+"#, options: .regularExpression) { link = String(link[r]) }
        guard let src = detect(link) else {
            return .failure(ImportError(message: "Нужна ссылка SoundCloud, Spotify или Яндекс Музыки"))
        }
        // короткие ссылки раскрываем
        if link.contains("on.soundcloud.com") || link.contains("spotify.link") || link.contains("music.yandex.ru/l/") {
            if let u = URL(string: link), let resolved = await resolveRedirect(u) { link = resolved }
        }
        switch src {
        case .soundcloud: return await soundcloud(link)
        case .spotify: return await spotify(link)
        case .yandex: return await yandex(link)
        case .file: return .failure(ImportError(message: "Это не ссылка"))
        }
    }

    static func resolveRedirect(_ u: URL) async -> String? {
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return (try? await URLSession.shared.data(for: req))?.1.url?.absoluteString
    }

    private static func getJSON(_ url: String, headers: [String: String] = [:]) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let res = try? await URLSession.shared.data(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: res.0)
    }

    // MARK: - SoundCloud

    private static func soundcloud(_ link: String) async -> Result<ImportResult, ImportError> {
        guard var components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].contains(host),
              components.user == nil, components.password == nil, components.port == nil else {
            return .failure(ImportError(message: "Нужна ссылка вида soundcloud.com/…"))
        }
        if host == "m.soundcloud.com" { components.host = "soundcloud.com" }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        let access = components.percentEncodedQueryItems?.filter { $0.name == "secret_token" } ?? []
        components.percentEncodedQueryItems = access.isEmpty ? nil : access
        components.fragment = nil
        guard !path.isEmpty, let u = components.string else {
            return .failure(ImportError(message: "Нужна ссылка вида soundcloud.com/…"))
        }
        let sounds = await SCResolver.resolve(u)
        guard !sounds.isEmpty else {
            return .failure(ImportError(message: "SoundCloud не открыл ссылку. Плейлист должен быть открытым или по секретной ссылке"))
        }
        let tracks = sounds.compactMap { s -> LTrack? in
            guard !s.permalink.isEmpty else { return nil }
            return LTrack(id: newID(), source: .soundcloud, title: s.title.isEmpty ? "Без названия" : s.title,
                          artist: s.user, art: art300(s.artwork), duration: s.dur / 1000, ref: s.permalink)
        }
        let isSet = u.contains("/sets/") || u.contains("/albums") || sounds.count > 1
        var name: String?
        var art = ""
        if isSet {
            let meta = await scMeta(u)
            name = meta?.0 ?? slugTitle(u)
            art = meta?.1 ?? (tracks.first?.art ?? "")
        }
        return .success(ImportResult(tracks: tracks, playlistName: name, art: art, origin: u))
    }

    private static func scMeta(_ url: String) async -> (String, String)? {
        guard let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let j = await getJSON("https://soundcloud.com/oembed?format=json&url=" + enc) as? [String: Any] else { return nil }
        return (j["title"] as? String ?? "", j["thumbnail_url"] as? String ?? "")
    }

    static func slugTitle(_ url: String) -> String {
        guard let path = URL(string: url)?.path else { return "Плейлист" }
        let parts = path.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0.range(of: #"^s-[A-Za-z0-9]+$"#, options: .regularExpression) == nil }
        let last = (parts.last ?? "Плейлист").removingPercentEncoding ?? "Плейлист"
        let t = last.replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return "Плейлист" }
        return f.uppercased() + t.dropFirst()
    }

    // MARK: - Spotify

    /// open.spotify.com/(intl-xx/)track|album|playlist/ID или spotify:track:ID
    static func spotifyParts(_ link: String) -> (String, String)? {
        if link.hasPrefix("spotify:") {
            let p = link.split(separator: ":").map(String.init)
            return p.count >= 3 ? (p[1], p[2]) : nil
        }
        guard let u = URL(string: link) else { return nil }
        let p = u.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") }
        guard p.count >= 2, ["track", "album", "playlist"].contains(p[0]) else { return nil }
        return (p[0], p[1])
    }

    private static func spotify(_ link: String) async -> Result<ImportResult, ImportError> {
        guard let parts = spotifyParts(link) else {
            return .failure(ImportError(message: "Нужна ссылка на трек, альбом или плейлист Spotify"))
        }
        let type = parts.0, id = parts.1
        guard let u = URL(string: "https://open.spotify.com/embed/\(type)/\(id)") else {
            return .failure(ImportError(message: "Неверная ссылка Spotify"))
        }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req),
              let html = String(data: res.0, encoding: .utf8),
              let entity = nextDataEntity(html) else {
            // запасной путь: только название трека через oEmbed
            if type == "track", let meta = await spotifyOEmbed("https://open.spotify.com/track/\(id)") {
                let t = LTrack(id: newID(), source: .spotify, title: meta.0, artist: "Spotify", art: meta.1, ref: "spotify:track:\(id)")
                return .success(ImportResult(tracks: [t], playlistName: nil, art: meta.1, origin: link))
            }
            return .failure(ImportError(message: "Spotify не отдал список треков. Попробуй позже"))
        }
        let cover = imageURL(entity)
        if type == "track" {
            let title = entity["name"] as? String ?? entity["title"] as? String ?? "Без названия"
            let artists = (entity["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let dur = (entity["duration"] as? NSNumber)?.doubleValue ?? 0
            let t = LTrack(id: newID(), source: .spotify, title: title, artist: artists ?? (entity["subtitle"] as? String ?? ""),
                           art: cover, duration: dur / 1000, ref: "spotify:track:\(id)")
            return .success(ImportResult(tracks: [t], playlistName: nil, art: cover, origin: link))
        }
        let list = entity["trackList"] as? [[String: Any]] ?? []
        let tracks: [LTrack] = list.compactMap { it in
            guard let uri = it["uri"] as? String, uri.hasPrefix("spotify:track:") else { return nil }
            let dur = (it["duration"] as? NSNumber)?.doubleValue ?? 0
            return LTrack(id: newID(), source: .spotify, title: it["title"] as? String ?? "Без названия",
                          artist: it["subtitle"] as? String ?? "", art: type == "album" ? cover : "",
                          duration: dur / 1000, ref: uri)
        }
        let name = entity["name"] as? String ?? entity["title"] as? String ?? "Плейлист Spotify"
        return .success(ImportResult(tracks: tracks, playlistName: name, art: cover, origin: "https://open.spotify.com/\(type)/\(id)"))
    }

    private static func nextDataEntity(_ html: String) -> [String: Any]? {
        guard let start = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else { return nil }
        let json = String(html[start.upperBound..<end.lowerBound])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let props = obj["props"] as? [String: Any],
              let page = props["pageProps"] as? [String: Any],
              let state = page["state"] as? [String: Any],
              let data = state["data"] as? [String: Any],
              let entity = data["entity"] as? [String: Any] else { return nil }
        return entity
    }

    private static func imageURL(_ e: [String: Any]) -> String {
        if let ca = e["coverArt"] as? [String: Any], let src = ca["sources"] as? [[String: Any]] {
            let sorted = src.sorted { (($0["width"] as? NSNumber)?.intValue ?? 0) > (($1["width"] as? NSNumber)?.intValue ?? 0) }
            if let u = sorted.first?["url"] as? String { return u }
        }
        if let vi = e["visualIdentity"] as? [String: Any], let imgs = vi["image"] as? [[String: Any]] {
            let sorted = imgs.sorted { (($0["maxWidth"] as? NSNumber)?.intValue ?? 0) > (($1["maxWidth"] as? NSNumber)?.intValue ?? 0) }
            if let u = sorted.first?["url"] as? String { return u }
        }
        if let imgs = e["images"] as? [[String: Any]], let u = imgs.first?["url"] as? String { return u }
        return ""
    }

    private static func spotifyOEmbed(_ url: String) async -> (String, String)? {
        guard let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let j = await getJSON("https://open.spotify.com/oembed?url=" + enc) as? [String: Any] else { return nil }
        return (j["title"] as? String ?? "", j["thumbnail_url"] as? String ?? "")
    }

    /// Обложка трека Spotify по spotify:track:ID
    static func spotifyThumb(_ uri: String) async -> String? {
        guard let id = uri.split(separator: ":").last else { return nil }
        return await spotifyOEmbed("https://open.spotify.com/track/\(id)")?.1
    }

    // MARK: - Яндекс Музыка

    private static let ya = "https://api.music.yandex.net"

    private static func yandex(_ link: String) async -> Result<ImportResult, ImportError> {
        guard let u = URL(string: link) else { return .failure(ImportError(message: "Неверная ссылка Яндекс Музыки")) }
        let p = u.path.split(separator: "/").map(String.init)
        func idx(_ key: String) -> String? {
            guard let i = p.firstIndex(of: key), i + 1 < p.count else { return nil }
            return p[i + 1]
        }
        let fail = ImportError(message: "Яндекс не отдал треки. Плейлист должен быть открытым; из-за границы Яндекс иногда не отвечает")

        // трек: /album/A/track/T или /track/T
        if let t = idx("track") {
            guard let res = (await getJSON("\(ya)/tracks/\(t)") as? [String: Any])?["result"] as? [[String: Any]],
                  let tr = res.first.flatMap({ yaTrack($0, albumHint: idx("album")) }) else { return .failure(fail) }
            return .success(ImportResult(tracks: [tr], playlistName: nil, art: tr.art, origin: link))
        }
        // альбом: /album/A
        if let a = idx("album") {
            guard let r = (await getJSON("\(ya)/albums/\(a)/with-tracks") as? [String: Any])?["result"] as? [String: Any] else { return .failure(fail) }
            let vols = r["volumes"] as? [[[String: Any]]] ?? []
            let tracks = vols.flatMap { $0 }.compactMap { yaTrack($0, albumHint: a) }
            return .success(ImportResult(tracks: tracks, playlistName: r["title"] as? String ?? "Альбом",
                                         art: yaCover(r["coverUri"] as? String), origin: link))
        }
        // плейлист: /users/OWNER/playlists/KIND или /playlists/UUID
        var r: [String: Any]?
        if let owner = idx("users"), let kind = idx("playlists") {
            r = (await getJSON("\(ya)/users/\(owner)/playlists/\(kind)?rich-tracks=true") as? [String: Any])?["result"] as? [String: Any]
        } else if let uuid = idx("playlists") {
            r = (await getJSON("\(ya)/playlist/\(uuid)?rich-tracks=true") as? [String: Any])?["result"] as? [String: Any]
        }
        guard let pl = r else { return .failure(ImportError(message: "Нужна ссылка на трек, альбом или плейлист Яндекс Музыки")) }
        let items = pl["tracks"] as? [[String: Any]] ?? []
        var tracks = items.compactMap { ($0["track"] as? [String: Any]).flatMap { yaTrack($0, albumHint: nil) } }
        if tracks.isEmpty {
            // треки пришли только номерами — дозапрашиваем
            let ids = items.compactMap { it -> String? in
                if let s = it["id"] as? String { return s }
                return (it["id"] as? NSNumber)?.stringValue
            }
            if !ids.isEmpty, let res = (await getJSON("\(ya)/tracks?track-ids=" + ids.prefix(300).joined(separator: ",")) as? [String: Any])?["result"] as? [[String: Any]] {
                tracks = res.compactMap { yaTrack($0, albumHint: nil) }
            }
        }
        var art = ""
        if let cover = pl["cover"] as? [String: Any] {
            art = yaCover(cover["uri"] as? String ?? (cover["itemsUri"] as? [String])?.first)
        }
        if art.isEmpty { art = yaCover(pl["ogImage"] as? String) }
        return .success(ImportResult(tracks: tracks, playlistName: pl["title"] as? String ?? "Плейлист", art: art, origin: link))
    }

    private static func yaCover(_ uri: String?) -> String {
        guard let uri, !uri.isEmpty else { return "" }
        return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
    }

    private static func yaTrack(_ j: [String: Any], albumHint: String?) -> LTrack? {
        let id: String
        if let s = j["id"] as? String { id = s } else if let n = j["id"] as? NSNumber { id = n.stringValue } else { return nil }
        if (j["available"] as? Bool) == false { return nil }
        var album = albumHint ?? ""
        if album.isEmpty, let albums = j["albums"] as? [[String: Any]], let a = albums.first {
            album = (a["id"] as? NSNumber)?.stringValue ?? (a["id"] as? String ?? "")
        }
        var title = j["title"] as? String ?? "Без названия"
        if let v = j["version"] as? String, !v.isEmpty { title += " (\(v))" }
        let artists = (j["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        let dur = (j["durationMs"] as? NSNumber)?.doubleValue ?? 0
        return LTrack(id: newID(), source: .yandex, title: title, artist: artists,
                      art: yaCover(j["coverUri"] as? String), duration: dur / 1000, ref: "\(id):\(album)")
    }
}

// MARK: - Список треков SoundCloud через скрытый официальный виджет

final class SCResolver: NSObject, WKScriptMessageHandler {
    private static var alive: [SCResolver] = []
    private var webView: WKWebView?
    private var done: (([SCSound]) -> Void)?

    static func resolve(_ url: String) async -> [SCSound] {
        await withCheckedContinuation { (cont: CheckedContinuation<[SCSound], Never>) in
            DispatchQueue.main.async {
                let r = SCResolver()
                alive.append(r)
                r.start(url) { list in
                    alive.removeAll { $0 === r }
                    cont.resume(returning: list)
                }
            }
        }
    }

    private func start(_ url: String, done: @escaping ([SCSound]) -> Void) {
        self.done = done
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "scr")
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: cfg)
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        keyWindow()?.addSubview(wv)
        webView = wv
        let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        let html = """
        <!doctype html><html><head><script src="https://w.soundcloud.com/player/api.js"></script></head><body>
        <iframe id="f" src="https://w.soundcloud.com/player/?url=\(enc)&auto_play=false"></iframe>
        <script>
        (function () {
          function post(d) { try { webkit.messageHandlers.scr.postMessage(d); } catch (e) {} }
          function slim(s) {
            if (!s) return null;
            return { id: s.id || 0, title: s.title || '', user: (s.user && s.user.username) || '',
                     avatar: (s.user && s.user.avatar_url) || '', art: s.artwork_url || '',
                     wave: s.waveform_url || '', dur: s.duration || 0, link: s.permalink_url || '' };
          }
          var w = SC.Widget(document.getElementById('f')), tries = 0;
          w.bind(SC.Widget.Events.READY, function () {
            (function go() {
              w.getSounds(function (l) {
                l = l || [];
                var missing = !l.length || l.some(function (s) { return !s.title || !s.permalink_url; });
                if (missing && tries++ < 30) { setTimeout(go, l.length ? 1500 : 500); return; }
                post((l || []).map(slim));
              });
            })();
          });
          w.bind(SC.Widget.Events.ERROR, function () { post([]); });
        })();
        </script></body></html>
        """
        wv.loadHTMLString(html, baseURL: URL(string: "https://led-lenta.vercel.app/"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish([]) }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let list = (message.body as? [Any] ?? []).compactMap { SCSound($0) }
        finish(list)
    }

    private func finish(_ list: [SCSound]) {
        guard let d = done else { return }
        done = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "scr")
        webView?.removeFromSuperview()
        webView = nil
        d(list)
    }
}

func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
}
