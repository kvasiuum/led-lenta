import Foundation
import AVFoundation
import UIKit

/// Откуда трек
enum TrackSource: String, Codable, CaseIterable {
    case file, soundcloud, spotify, yandex

    var title: String {
        switch self {
        case .file: return "Свой файл"
        case .soundcloud: return "SoundCloud"
        case .spotify: return "Spotify"
        case .yandex: return "Яндекс Музыка"
        }
    }

    /// Короткая метка в списке
    var badge: String {
        switch self {
        case .file: return "MP3"
        case .soundcloud: return "SC"
        case .spotify: return "S"
        case .yandex: return "Я"
        }
    }

    var tint: (Double, Double, Double) {
        switch self {
        case .file: return (0.55, 0.57, 0.62)
        case .soundcloud: return (1.0, 0.45, 0.1)
        case .spotify: return (0.12, 0.84, 0.38)
        case .yandex: return (1.0, 0.8, 0.0)
        }
    }
}

/// Трек в библиотеке
struct LTrack: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var source: TrackSource
    var title: String
    var artist: String
    /// Обложка: адрес в сети, а у своих файлов — имя файла обложки
    var art: String = ""
    /// Секунды, 0 — неизвестно
    var duration: Double = 0
    /// file: имя копии; soundcloud: ссылка на трек; spotify: spotify:track:ID; yandex: "trackId:albumId"
    var ref: String = ""
    var size: Int = 0
    var origName: String = ""
}

/// Плейлист: свой (из выбранных треков) или перенесённый по ссылке
struct Playlist: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var art: String = ""
    var trackIDs: [String] = []
    /// Ссылка, из которой импортирован
    var origin: String = ""
}

func newID() -> String { UUID().uuidString }

/// Все треки и плейлисты. Хранятся в приложении и остаются после перезапуска.
final class LibraryStore: ObservableObject {
    private var s: Services { .shared }

    @Published private(set) var tracks: [LTrack] = Prefs.get("lib.tracks", [LTrack]())
    @Published private(set) var playlists: [Playlist] = Prefs.get("lib.playlists", [Playlist]())
    /// Пока идёт импорт по ссылке
    @Published private(set) var busy: String?

    static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        migrate()
        // убрать свои треки, файлов которых больше нет
        let ok = tracks.filter { $0.source != .file || FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.ref).path) }
        if ok.count != tracks.count { tracks = ok; save() }
    }

    func track(_ id: String) -> LTrack? { tracks.first { $0.id == id } }

    func tracks(of p: Playlist) -> [LTrack] { p.trackIDs.compactMap { track($0) } }

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    func fileURL(_ t: LTrack) -> URL { Self.dir.appendingPathComponent(t.ref) }

    func artSource(_ t: LTrack?) -> ArtSource {
        guard let t, !t.art.isEmpty else { return .empty }
        return t.source == .file ? .file(Self.dir.appendingPathComponent(t.art)) : .web(t.art)
    }

    func artSource(_ p: Playlist) -> ArtSource {
        if !p.art.isEmpty { return .web(p.art) }
        for id in p.trackIDs {
            let a = artSource(track(id))
            if a != .empty { return a }
        }
        return .empty
    }

    private func save() {
        Prefs.set("lib.tracks", tracks)
        Prefs.set("lib.playlists", playlists)
    }

    // MARK: - Добавление

    /// Добавить треки; повторы (тот же источник и ссылка) не дублируются. Возвращает id в том же порядке.
    @discardableResult
    func add(_ list: [LTrack]) -> [String] {
        var ids: [String] = []
        for t in list {
            if let have = tracks.first(where: { $0.source == t.source && $0.ref == t.ref && !t.ref.isEmpty }) {
                ids.append(have.id)
                // дополнить пустые поля
                if let k = tracks.firstIndex(of: have) {
                    if tracks[k].art.isEmpty && !t.art.isEmpty { tracks[k].art = t.art }
                    if tracks[k].duration == 0 && t.duration > 0 { tracks[k].duration = t.duration }
                }
            } else {
                tracks.append(t)
                ids.append(t.id)
            }
        }
        save()
        return ids
    }

    func update(_ id: String, _ change: (inout LTrack) -> Void) {
        guard let k = tracks.firstIndex(where: { $0.id == id }) else { return }
        change(&tracks[k])
        save()
    }

    /// Свои файлы из «Файлов»: копируются в приложение, теги и обложка читаются потом
    func addFiles(_ urls: [URL]) {
        var added: [LTrack] = []
        var dup = 0, failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if tracks.contains(where: { $0.source == .file && $0.origName == name && $0.size == size }) { dup += 1; continue }
            let id = newID()
            let file = id + "." + (url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: Self.dir.appendingPathComponent(file))
                added.append(LTrack(id: id, source: .file, title: (name as NSString).deletingPathExtension,
                                    artist: "Свой трек", ref: file, size: size, origName: name))
            } catch {
                failed += 1
            }
        }
        if added.isEmpty {
            s.app.showToast(dup > 0 ? "Эти треки уже в списке" : "Не удалось добавить файлы")
            return
        }
        add(added)
        s.app.showToast("Добавлено: \(added.count) \(plural(added.count, "трек", "трека", "треков"))"
                        + (failed > 0 ? ", не вышло: \(failed)" : ""))
        for t in added { Task { await self.loadTags(t) } }
    }

    private func loadTags(_ t: LTrack) async {
        let asset = AVURLAsset(url: Self.dir.appendingPathComponent(t.ref))
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
        let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        await MainActor.run {
            self.update(t.id) { tr in
                if let title, !title.isEmpty { tr.title = title }
                if let artist, !artist.isEmpty { tr.artist = artist }
                if let artFile { tr.art = artFile }
                if dur.isFinite && dur > 0 { tr.duration = dur }
            }
            self.s.player.changed()
        }
    }

    /// Ссылка SoundCloud / Spotify / Яндекс. asPlaylist — сохранить набор как плейлист
    func importLink(_ text: String, asPlaylist: Bool = true, into playlistID: String? = nil) {
        guard busy == nil else { s.app.showToast("Подожди, предыдущая ссылка ещё загружается"); return }
        busy = "Загружаю…"
        Task {
            let r = await Importer.load(text)
            await MainActor.run {
                self.busy = nil
                switch r {
                case .failure(let e):
                    self.s.app.showToast(e.message)
                case .success(let res):
                    guard !res.tracks.isEmpty else { self.s.app.showToast("В ссылке не нашлось треков"); return }
                    let ids = self.add(res.tracks)
                    if let pid = playlistID {
                        self.addToPlaylist(pid, ids)
                        if let k = self.playlists.firstIndex(where: { $0.id == pid }) {
                            if self.playlists[k].art.isEmpty { self.playlists[k].art = res.art }
                            self.save()
                        }
                        self.s.app.showToast("Загружено: \(ids.count) \(plural(ids.count, "трек", "трека", "треков"))")
                    } else if asPlaylist, let name = res.playlistName {
                        if let k = self.playlists.firstIndex(where: { $0.origin == res.origin && !res.origin.isEmpty }) {
                            self.playlists[k].trackIDs = ids
                            self.save()
                        } else {
                            self.playlists.insert(Playlist(id: newID(), name: name, art: res.art, trackIDs: ids, origin: res.origin), at: 0)
                            self.save()
                        }
                        self.s.app.showToast("Плейлист «\(name)»: \(ids.count) \(plural(ids.count, "трек", "трека", "треков"))")
                    } else {
                        self.s.app.showToast(ids.count == 1 ? "Трек добавлен" : "Добавлено: \(ids.count) \(plural(ids.count, "трек", "трека", "треков"))")
                    }
                    self.fillMissingArt()
                }
            }
        }
    }

    /// У треков Spotify из плейлистов нет обложек — дотягиваем по одной
    private var filling = false
    func fillMissingArt() {
        guard !filling else { return }
        let need = tracks.filter { $0.source == .spotify && $0.art.isEmpty }.prefix(60)
        guard !need.isEmpty else { return }
        filling = true
        Task {
            for t in need {
                if let art = await Importer.spotifyThumb(t.ref) {
                    await MainActor.run { self.update(t.id) { $0.art = art } }
                }
            }
            await MainActor.run { self.filling = false }
        }
    }

    // MARK: - Порядок

    /// Перетащили трек на место другого
    func moveTrack(_ id: String, to target: String) {
        guard id != target, let from = tracks.firstIndex(where: { $0.id == id }),
              let to = tracks.firstIndex(where: { $0.id == target }) else { return }
        let t = tracks.remove(at: from)
        tracks.insert(t, at: to)
        save()
    }

    func moveTrackToEdge(_ id: String, top: Bool) {
        guard let from = tracks.firstIndex(where: { $0.id == id }) else { return }
        let t = tracks.remove(at: from)
        if top { tracks.insert(t, at: 0) } else { tracks.append(t) }
        save()
    }

    func moveInPlaylist(_ pid: String, _ id: String, to target: String) {
        guard id != target, let k = playlists.firstIndex(where: { $0.id == pid }),
              let from = playlists[k].trackIDs.firstIndex(of: id),
              let to = playlists[k].trackIDs.firstIndex(of: target) else { return }
        let x = playlists[k].trackIDs.remove(at: from)
        playlists[k].trackIDs.insert(x, at: to)
        save()
    }

    // MARK: - Удаление

    func removeTracks(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        s.player.removed(ids)
        for t in tracks where ids.contains(t.id) && t.source == .file {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(t.ref))
            if !t.art.isEmpty { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(t.art)) }
        }
        tracks.removeAll { ids.contains($0.id) }
        for k in playlists.indices { playlists[k].trackIDs.removeAll { ids.contains($0) } }
        save()
    }

    // MARK: - Плейлисты

    @discardableResult
    func createPlaylist(_ name: String, _ ids: [String]) -> Playlist {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = Playlist(id: newID(), name: n.isEmpty ? "Новый плейлист" : n, trackIDs: ids)
        playlists.insert(p, at: 0)
        save()
        return p
    }

    func addToPlaylist(_ pid: String, _ ids: [String]) {
        guard let k = playlists.firstIndex(where: { $0.id == pid }) else { return }
        for id in ids where !playlists[k].trackIDs.contains(id) { playlists[k].trackIDs.append(id) }
        save()
    }

    func removeFromPlaylist(_ pid: String, at offsets: IndexSet) {
        guard let k = playlists.firstIndex(where: { $0.id == pid }) else { return }
        playlists[k].trackIDs.remove(atOffsets: offsets)
        save()
    }

    func movePlaylistTracks(_ pid: String, from: IndexSet, to: Int) {
        guard let k = playlists.firstIndex(where: { $0.id == pid }) else { return }
        playlists[k].trackIDs.move(fromOffsets: from, toOffset: to)
        save()
    }

    func renamePlaylist(_ pid: String, _ name: String) {
        guard let k = playlists.firstIndex(where: { $0.id == pid }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { playlists[k].name = n; save() }
    }

    func deletePlaylist(_ pid: String) {
        playlists.removeAll { $0.id == pid }
        save()
    }

    // MARK: - Перенос со старой версии

    private struct OldTrack: Codable { var id: String; var name: String; var file: String; var size: Int; var title: String?; var artist: String?; var art: String? }
    private struct OldSC: Codable { var url: String; var title: String; var art: String }

    private func migrate() {
        guard !Prefs.get("lib.migrated", false) else { return }
        let old: [OldTrack] = Prefs.get("tracks", [OldTrack]())
        for o in old {
            tracks.append(LTrack(id: o.id, source: .file, title: o.title ?? (o.name as NSString).deletingPathExtension,
                                 artist: o.artist ?? "Свой трек", art: o.art ?? "", ref: o.file, size: o.size, origName: o.name))
        }
        let sc: [OldSC] = Prefs.get("scLib", [OldSC]())
        for o in sc {
            playlists.append(Playlist(id: newID(), name: o.title, art: o.art, trackIDs: [], origin: o.url))
        }
        Prefs.set("lib.migrated", true)
        save()
    }
}
