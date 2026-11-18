import Foundation
import AVFoundation
import UIKit

struct Track: Codable, Identifiable, Equatable {
    var id: String
    var name: String          // имя файла, как его выбрали
    var file: String          // имя копии в Documents/Tracks
    var size: Int
    var title: String?
    var artist: String?
    var art: String?          // обложка рядом с файлом

    var displayTitle: String { title ?? (name as NSString).deletingPathExtension }
}

/// Свои треки: копируются в приложение и остаются после перезапуска.
final class LocalLibrary: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var s: Services { .shared }

    @Published private(set) var tracks: [Track] = Prefs.get("tracks", [Track]())
    @Published private(set) var cur = -1
    @Published private(set) var isPlaying = false

    private(set) var player: AVAudioPlayer?
    private(set) var analysis: FileAnalysis?

    static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        // убрать записи о файлах, которых больше нет
        let ok = tracks.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
        if ok.count != tracks.count { tracks = ok; save() }
    }

    var current: Track? { tracks.indices.contains(cur) ? tracks[cur] : nil }
    var position: Double { player?.currentTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }

    func artURL(_ t: Track) -> URL? { t.art.map { Self.dir.appendingPathComponent($0) } }

    private func save() { Prefs.set("tracks", tracks) }

    // MARK: - Добавление и удаление

    func add(urls: [URL]) {
        var added: [Track] = []
        var dup = 0, failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if tracks.contains(where: { $0.name == name && $0.size == size }) || added.contains(where: { $0.name == name && $0.size == size }) {
                dup += 1; continue
            }
            let id = UUID().uuidString
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let file = id + "." + ext
            do {
                try FileManager.default.copyItem(at: url, to: Self.dir.appendingPathComponent(file))
                added.append(Track(id: id, name: name, file: file, size: size))
            } catch {
                failed += 1
            }
        }
        if added.isEmpty {
            if dup > 0 { s.app.showToast("Эти треки уже в списке") }
            else if failed > 0 { s.app.showToast("Не удалось добавить файлы") }
            return
        }
        let first = tracks.count
        tracks.append(contentsOf: added)
        save()
        if failed > 0 { s.app.showToast("Не добавлено: \(failed) \(plural(failed, "файл", "файла", "файлов"))") }
        if cur < 0 || !isPlaying { play(first) }
        for t in added { Task { await self.loadMetadata(t) } }
    }

    /// Название, исполнитель и обложка из тегов файла
    private func loadMetadata(_ t: Track) async {
        let asset = AVURLAsset(url: Self.dir.appendingPathComponent(t.file))
        guard let items = try? await asset.load(.commonMetadata) else { return }
        var title: String?, artist: String?, artFile: String?
        if let i = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first {
            title = try? await i.load(.stringValue)
        }
        if let i = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist).first {
            artist = try? await i.load(.stringValue)
        }
        if let i = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await i.load(.dataValue), let img = UIImage(data: data),
           let jpg = img.jpegData(compressionQuality: 0.85) {
            let f = t.id + "-art.jpg"
            if (try? jpg.write(to: Self.dir.appendingPathComponent(f))) != nil { artFile = f }
        }
        await MainActor.run {
            guard let k = self.tracks.firstIndex(where: { $0.id == t.id }) else { return }
            if let title, !title.isEmpty { self.tracks[k].title = title }
            if let artist, !artist.isEmpty { self.tracks[k].artist = artist }
            if let artFile { self.tracks[k].art = artFile }
            self.save()
            if k == self.cur { self.s.player.refreshNowPlaying() }
        }
    }

    func remove(_ i: Int) {
        guard tracks.indices.contains(i) else { return }
        let t = tracks[i]
        if i == cur {
            player?.stop(); player = nil
            analysis?.cancel(); analysis = nil
            cur = -1
            setPlaying(false)
        } else if i < cur {
            cur -= 1
        }
        tracks.remove(at: i)
        save()
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(t.file))
        if let a = t.art { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(a)) }
        s.player.changed()
    }

    // MARK: - Воспроизведение

    func play(_ i: Int) {
        guard !tracks.isEmpty else { return }
        let k = ((i % tracks.count) + tracks.count) % tracks.count
        cur = k
        s.player.setActive(.file)
        AudioSessionManager.activate()
        player?.stop()
        analysis?.cancel()
        let url = Self.dir.appendingPathComponent(tracks[k].file)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            analysis = FileAnalysis(url: url)
            p.play()
            setPlaying(true)
        } catch {
            player = nil
            analysis = nil
            setPlaying(false)
            s.app.showToast("Не получается открыть «\(tracks[k].displayTitle)»")
        }
    }

    func toggle() {
        guard let p = player else { if cur >= 0 { play(cur) } else if !tracks.isEmpty { play(0) }; return }
        if p.isPlaying { p.pause(); setPlaying(false) }
        else {
            s.player.setActive(.file)
            AudioSessionManager.activate()
            p.play(); setPlaying(true)
        }
    }

    func pause() {
        guard let p = player, p.isPlaying else { return }
        p.pause()
        setPlaying(false)
    }

    func seek(_ t: Double) {
        player?.currentTime = clamp(t, 0, duration)
        s.player.refreshNowPlaying()
    }

    func next() {
        if let i = s.player.pickNext(cur, tracks.count, auto: false) { play(i) }
    }

    func prev() {
        if position > 3 { seek(0); return }
        play(s.player.shuffle ? rnd(tracks.count, not: cur) : cur - 1)
    }

    private func setPlaying(_ on: Bool) {
        if isPlaying != on { isPlaying = on }
        s.player.changed()
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard p === self.player else { return }
            if self.s.player.repeatMode == .one {
                p.currentTime = 0
                p.play()
                self.s.player.changed()
                return
            }
            if let i = self.s.player.pickNext(self.cur, self.tracks.count, auto: true) { self.play(i) }
            else { self.setPlaying(false) }
        }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began { self.setPlaying(false) }
        }
    }
}
