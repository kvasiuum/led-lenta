import Foundation
import Combine
import MediaPlayer
import UIKit

/// Свои треки и SoundCloud делят один плеер: мини-полоска внизу, полный экран, экран блокировки.
final class PlayerController: ObservableObject {
    private var s: Services { .shared }

    enum Src { case file, sc }
    enum Repeat: String, Codable {
        case off, all, one
        var next: Repeat { self == .off ? .all : self == .all ? .one : .off }
        var label: String {
            switch self {
            case .off: return "Повтор выключен"
            case .all: return "Плейлист по кругу"
            case .one: return "Повтор одного трека"
            }
        }
    }

    @Published private(set) var active: Src?
    @Published private(set) var shuffle: Bool = Prefs.get("shuffle", false)
    @Published private(set) var repeatMode: Repeat = Prefs.get("repeat", Repeat.off)
    @Published var showFull = false

    private var bag = Set<AnyCancellable>()
    private var artCache: (String, UIImage)?
    private var lastMetaKey = ""

    /// Перерисовывать плеер, когда меняются треки или SoundCloud
    func wire() {
        s.library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        s.sc.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        setupRemote()
    }

    // MARK: - Какой трек следующий

    /// nil — остановиться; auto — прошлый трек закончился сам
    func pickNext(_ i: Int, _ n: Int, auto: Bool) -> Int? {
        guard n > 0 else { return nil }
        if auto && repeatMode == .one { return i }
        if shuffle { return rnd(n, not: i) }
        if i + 1 < n { return i + 1 }
        return (repeatMode == .all || !auto) ? 0 : nil
    }

    func toggleShuffle() {
        shuffle.toggle()
        Prefs.set("shuffle", shuffle)
        s.app.showToast(shuffle ? "Случайный порядок" : "По порядку")
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        Prefs.set("repeat", repeatMode)
        s.app.showToast(repeatMode.label)
    }

    // MARK: - Активный источник

    func setActive(_ src: Src) {
        guard active != src else { return }
        pauseActive()
        active = src
        changed()
    }

    func pauseActive() {
        switch active {
        case .file: s.library.pause()
        case .sc: s.sc.pause()
        case nil: break
        }
    }

    /// Что-то поменялось: свет, экран блокировки, фоновый режим
    func changed() {
        s.light.refresh()
        refreshNowPlaying()
        s.timers.updateKeepAlive()
    }

    var has: Bool {
        switch active {
        case .file: return s.library.current != nil
        case .sc: return s.sc.has
        case nil: return false
        }
    }

    var playing: Bool {
        switch active {
        case .file: return s.library.isPlaying
        case .sc: return s.sc.playing
        case nil: return false
        }
    }

    var title: String {
        switch active {
        case .file: return s.library.current?.displayTitle ?? ""
        case .sc:
            if let c = s.sc.currentSound, !c.title.isEmpty { return c.title }
            return s.sc.title.isEmpty ? "SoundCloud" : s.sc.title
        case nil: return ""
        }
    }

    var artist: String {
        switch active {
        case .file: return s.library.current?.artist ?? "Свой трек"
        case .sc: return s.sc.currentSound?.user ?? "SoundCloud"
        case nil: return ""
        }
    }

    var album: String { active == .sc ? (s.sc.title.isEmpty ? "SoundCloud" : s.sc.title) : "Свои треки" }

    /// Обложка: локальный файл или адрес в сети
    var art: ArtSource {
        switch active {
        case .file:
            if let t = s.library.current, let u = s.library.artURL(t) { return .local(u) }
            return .empty
        case .sc:
            let a = s.sc.artURLString
            guard !a.isEmpty, let u = URL(string: a) else { return .empty }
            return .remote(u)
        case nil: return .empty
        }
    }

    var position: Double {
        switch active {
        case .file: return s.library.position
        case .sc: return s.sc.nowPos() / 1000
        case nil: return 0
        }
    }

    var duration: Double {
        switch active {
        case .file: return s.library.duration
        case .sc: return s.sc.dur / 1000
        case nil: return 0
        }
    }

    func toggle() {
        switch active {
        case .file: s.library.toggle()
        case .sc: s.sc.toggle()
        case nil: break
        }
    }

    func next() {
        switch active {
        case .file: s.library.next()
        case .sc: s.sc.next()
        case nil: break
        }
    }

    func prev() {
        switch active {
        case .file: s.library.prev()
        case .sc: s.sc.prev()
        case nil: break
        }
    }

    func seek(_ t: Double) {
        switch active {
        case .file: s.library.seek(t)
        case .sc: s.sc.seek(t)
        case nil: break
        }
    }

    // MARK: - Экран блокировки и пульт

    func refreshNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard has else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        let key = art.key
        if let c = artCache, c.0 == key {
            let img = c.1
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        } else if !key.isEmpty {
            loadArt(art) { [weak self] img in
                guard let self, let img else { return }
                self.artCache = (key, img)
                self.refreshNowPlaying()
            }
        }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    private func loadArt(_ a: ArtSource, done: @escaping (UIImage?) -> Void) {
        switch a {
        case .local(let u): done(UIImage(contentsOfFile: u.path))
        case .remote(let u):
            URLSession.shared.dataTask(with: u) { data, _, _ in
                let img = data.flatMap { UIImage(data: $0) }
                DispatchQueue.main.async { done(img) }
            }.resume()
        case .empty: done(nil)
        }
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let self, self.has else { return .noActionableNowPlayingItem }
            if !self.playing { self.toggle() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.has else { return .noActionableNowPlayingItem }
            if self.playing { self.toggle() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.has else { return .noActionableNowPlayingItem }
            self.toggle()
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.has else { return .noActionableNowPlayingItem }
            self.next()
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.has else { return .noActionableNowPlayingItem }
            self.prev()
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(e.positionTime)
            return .success
        }
    }
}

enum ArtSource: Equatable {
    case empty, local(URL), remote(URL)

    static func web(_ s: String) -> ArtSource {
        guard !s.isEmpty, let u = URL(string: s) else { return .empty }
        return .remote(u)
    }

    static func file(_ u: URL?) -> ArtSource {
        guard let u else { return .empty }
        return .local(u)
    }

    var key: String {
        switch self {
        case .empty: return ""
        case .local(let u), .remote(let u): return u.absoluteString
        }
    }
}
