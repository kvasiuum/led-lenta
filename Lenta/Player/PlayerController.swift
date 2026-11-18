import Foundation
import Combine
import MediaPlayer
import UIKit
import SwiftUI

/// Один плеер на все источники: очередь треков, случайный порядок, повтор, экран блокировки.
final class PlayerController: ObservableObject {
    private var s: Services { .shared }

    enum Repeat: String, Codable {
        case off, all, one
        var next: Repeat { self == .off ? .all : self == .all ? .one : .off }
        var label: String {
            switch self {
            case .off: return "Повтор выключен"
            case .all: return "Повтор плейлиста"
            case .one: return "Повтор трека"
            }
        }
    }

    @Published private(set) var queue: [String] = []
    @Published private(set) var index = -1
    /// Откуда играем: «Все треки» или название плейлиста
    @Published private(set) var context = ""
    @Published private(set) var shuffle: Bool = Prefs.get("shuffle", false)
    @Published private(set) var repeatMode: Repeat = Prefs.get("repeat", Repeat.off)
    @Published var showFull = false
    /// Плеер внизу: большая карточка или компактная полоска
    @Published private(set) var expanded = true
    /// Реальная высота плеера внизу — под неё страница делает отступ
    @Published var dockHeight: CGFloat = 0
    private var expandedAt = Date.distantPast
    private var idleWork: DispatchWorkItem?

    private var bag = Set<AnyCancellable>()
    private var artCache: (String, UIImage)?
    /// Для «назад» в случайном порядке
    private var history: [Int] = []

    func wire() {
        s.files.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        s.web.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        s.library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        setupRemote()
    }

    // MARK: - Что играет

    var current: LTrack? {
        guard queue.indices.contains(index) else { return nil }
        return s.library.track(queue[index])
    }

    var has: Bool { current != nil }

    var playing: Bool {
        guard let c = current else { return false }
        return c.source == .file ? s.files.isPlaying : s.web.playing
    }

    var title: String { current?.title ?? "" }
    var artist: String { current.map { $0.artist.isEmpty ? $0.source.title : $0.artist } ?? "" }
    var art: ArtSource { s.library.artSource(current) }

    var position: Double {
        guard let c = current else { return 0 }
        return c.source == .file ? s.files.position : s.web.nowPos() / 1000
    }

    var duration: Double {
        guard let c = current else { return 0 }
        if c.source == .file { return s.files.duration }
        return s.web.dur > 0 ? s.web.dur / 1000 : c.duration
    }

    // MARK: - Карточка внизу

    func setExpanded(_ on: Bool) {
        if on { expandedAt = Date(); touchDock() } else { idleWork?.cancel() }
        guard on != expanded else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expanded = on }
    }

    /// Карточку трогали — отложить сворачивание. Без касаний она сворачивается сама через 5 с
    func touchDock() {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.expanded, !self.showFull else { return }
            self.setExpanded(false)
        }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    /// Коснулись страницы или прокрутили — сворачиваем (но не сразу после раскрытия)
    func collapseFromPage() {
        guard expanded, has, Date().timeIntervalSince(expandedAt) > 0.6 else { return }
        setExpanded(false)
    }

    // MARK: - Запуск

    /// Играть список; start — с какого трека; nil при shuffle — со случайного
    func play(_ ids: [String], start: Int?, context: String) {
        guard !ids.isEmpty else { return }
        if !has { setExpanded(true) }        // первый трек — показываем карточку
        queue = ids
        self.context = context
        history = []
        let i = start ?? (shuffle ? Int.random(in: 0..<ids.count) : 0)
        playAt(i)
    }

    func playShuffled(_ ids: [String], context: String) {
        if !shuffle { shuffle = true; Prefs.set("shuffle", true) }
        play(ids, start: nil, context: context)
    }

    private func playAt(_ i: Int) {
        guard !queue.isEmpty else { return }
        let k = ((i % queue.count) + queue.count) % queue.count
        guard let t = s.library.track(queue[k]) else { return }
        if index >= 0 && index != k { history.append(index); if history.count > 200 { history.removeFirst() } }
        index = k
        if t.source == .file {
            s.web.stop()
            s.files.play(t, url: s.library.fileURL(t))
        } else {
            s.files.stop()
            s.web.load(t)
        }
        changed()
    }

    /// nil — остановиться; auto — прошлый трек закончился сам
    func pickNext(_ i: Int, _ n: Int, auto: Bool) -> Int? {
        guard n > 0 else { return nil }
        if auto && repeatMode == .one { return i }
        if shuffle { return rnd(n, not: i) }
        if i + 1 < n { return i + 1 }
        return (repeatMode == .all || !auto) ? 0 : nil
    }

    // MARK: - Кнопки

    func toggle() {
        guard let c = current else { return }
        if c.source == .file {
            if s.files.trackID == c.id { s.files.toggle() } else { playAt(index) }
        } else {
            if s.web.trackID == c.id { s.web.toggle() } else { playAt(index) }
        }
    }

    func pauseActive() {
        s.files.pause()
        s.web.pause()
    }

    func next() {
        if let i = pickNext(index, queue.count, auto: false) { playAt(i) }
    }

    func prev() {
        if position > 3 { seek(0); return }
        if shuffle, let last = history.popLast() {
            index = -1          // не записывать «назад» в историю
            playAt(last)
            return
        }
        playAt(index - 1)
    }

    func seek(_ t: Double) {
        guard let c = current else { return }
        if c.source == .file { s.files.seek(t) } else { s.web.seek(t) }
        refreshNowPlaying()
    }

    func playIndex(_ i: Int) { playAt(i) }

    /// Трек доиграл сам
    func trackEnded() {
        guard let c = current else { return }
        if repeatMode == .one {
            if c.source == .file { s.files.restart() } else { s.web.restart() }
            return
        }
        if let i = pickNext(index, queue.count, auto: true) { playAt(i) } else { changed() }
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

    /// Треки удалены из библиотеки
    func removed(_ ids: Set<String>) {
        let cur = queue.indices.contains(index) ? queue[index] : nil
        if let cur, ids.contains(cur) {
            s.files.stop(); s.web.stop()
        }
        queue.removeAll { ids.contains($0) }
        history = []
        if let cur, let k = queue.firstIndex(of: cur) { index = k } else { index = -1 }
        changed()
    }

    /// Что-то поменялось: свет, экран блокировки, фоновый режим
    func changed() {
        s.light.refresh()
        refreshNowPlaying()
        s.timers.updateKeepAlive()
    }

    // MARK: - Экран блокировки и пульт

    func refreshNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard has else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: context,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        let a = art, key = a.key
        if let c = artCache, c.0 == key {
            let img = c.1
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        } else if !key.isEmpty {
            loadArt(a) { [weak self] img in
                guard let self, let img else { return }
                self.artCache = (key, img)
                self.refreshNowPlaying()
            }
        }
        center.nowPlayingInfo = info
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
