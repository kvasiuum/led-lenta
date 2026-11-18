import SwiftUI
import WebKit

/// Метка сервиса: MP3 · SC · S · Я
struct SourceBadge: View {
    let source: TrackSource

    var body: some View {
        let c = source.tint
        Text(source.badge)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(source == .yandex ? Color.black : Color.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Color(red: c.0, green: c.1, blue: c.2), in: Capsule())
            .accessibilityLabel(source.title)
    }
}

/// Строка трека
struct TrackRow: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    let track: LTrack
    var selecting = false
    var selected = false
    let action: () -> Void

    var body: some View {
        let cur = player.current?.id == track.id
        Button(action: action) {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.35))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                ZStack {
                    ArtThumb(source: library.artSource(track), size: 44, radius: 9)
                    if cur {
                        Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        if player.playing {
                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                        } else {
                            Image(systemName: "pause.fill").font(.footnote)
                        }
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1).fontWeight(cur ? .semibold : .regular)
                    HStack(spacing: 5) {
                        SourceBadge(source: track.source)
                        Text(track.artist).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if track.duration > 0 {
                    Text(fmtTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(cur || selected ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// «Слушать» и «Перемешать»
struct PlayShuffleRow: View {
    @EnvironmentObject var player: PlayerController
    let ids: [String]
    let context: String

    var body: some View {
        HStack(spacing: 8) {
            Button { player.play(ids, start: 0, context: context) } label: {
                Label("Слушать", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button { player.playShuffled(ids, context: context) } label: {
                Label("Перемешать", systemImage: "shuffle")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .disabled(ids.isEmpty)
    }
}

/// «Загружаю…», пока идёт импорт по ссылке
struct BusyLine: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        if let b = library.busy {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(b).font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Добавить по ссылке

struct AddLinkSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let asPlaylist: Bool
    let into: String?
    @State private var link = ""
    @State private var account: TrackSource?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    Button("Вставить из буфера", systemImage: "doc.on.clipboard") {
                        if let t = UIPasteboard.general.string { link = t }
                    }
                } header: {
                    Text(asPlaylist ? "Ссылка на плейлист, альбом или трек" : "Ссылка на трек, альбом или плейлист")
                } footer: {
                    if let src = Importer.detect(link) {
                        HStack(spacing: 6) { SourceBadge(source: src); Text(src.title) }
                    } else {
                        Text("В приложении сервиса: «Поделиться» → «Копировать ссылку».")
                    }
                }

                Section("Откуда") {
                    row(.soundcloud, "Треки, альбомы и плейлисты. Играют целиком, свет по форме волны.")
                    row(.spotify, "Треки, альбомы и плейлисты. Без входа — отрывки по 30 секунд, с Premium — целиком.")
                    row(.yandex, "Треки, альбомы и открытые плейлисты. Целиком — после входа в аккаунт с Плюсом.")
                }

                Section {
                    Button("Войти в Spotify", systemImage: "person.crop.circle") { account = .spotify }
                    Button("Войти в Яндекс", systemImage: "person.crop.circle") { account = .yandex }
                } header: {
                    Text("Полные треки")
                } footer: {
                    Text("Вход нужен один раз: встроенные плееры запомнят аккаунт.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .navigationTitle(asPlaylist ? "Перенести плейлист" : "Добавить по ссылке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        library.importLink(link, asPlaylist: asPlaylist, into: into)
                        dismiss()
                    }
                    .disabled(Importer.detect(link) == nil)
                }
            }
            .sheet(item: $account) { AccountSheet(service: $0) }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if link.isEmpty, let t = UIPasteboard.general.string, Importer.detect(t) != nil { link = t }
        }
    }

    private func row(_ s: TrackSource, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SourceBadge(source: s).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

extension TrackSource: Identifiable {
    var id: String { rawValue }
}

// MARK: - Вход в Spotify / Яндекс для полных треков

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: TrackSource

    var body: some View {
        NavigationStack {
            LoginWebView(url: loginURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(service == .spotify ? "Вход в Spotify" : "Вход в Яндекс")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                }
        }
    }

    private var loginURL: URL {
        let s = service == .spotify
            ? "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"
            : "https://passport.yandex.ru/auth?retpath=https%3A%2F%2Fmusic.yandex.ru%2F"
        return URL(string: s)!
    }
}

/// Тот же набор cookie, что и у встроенных плееров, поэтому вход сохраняется
struct LoginWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.customUserAgent = Importer.ua
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Плейлист

struct PlaylistDetail: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    let pid: String
    @State private var renaming = false
    @State private var newName = ""
    @State private var picking = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let p = library.playlist(pid) {
                    content(p)
                } else {
                    Text("Плейлист удалён").foregroundStyle(.secondary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    EditButton()
                    Menu {
                        Button("Добавить треки", systemImage: "plus") { picking = true }
                        Button("Переименовать", systemImage: "pencil") {
                            newName = library.playlist(pid)?.name ?? ""
                            renaming = true
                        }
                        if let o = library.playlist(pid)?.origin, !o.isEmpty {
                            Button("Обновить по ссылке", systemImage: "arrow.clockwise") { library.importLink(o, into: pid) }
                        }
                        Button("Удалить плейлист", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Название плейлиста", isPresented: $renaming) {
                TextField("Название", text: $newName)
                Button("Сохранить") { library.renamePlaylist(pid, newName) }
                Button("Отмена", role: .cancel) {}
            }
            .confirmationDialog("Удалить плейлист?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { library.deletePlaylist(pid); dismiss() }
            } message: {
                Text("Сами треки останутся во вкладке «Треки».")
            }
            .sheet(isPresented: $picking) { TrackPicker(pid: pid) }
        }
        .preferredColorScheme(.dark)
    }

    private func content(_ p: Playlist) -> some View {
        let tracks = library.tracks(of: p)
        return List {
            Section {
                VStack(spacing: 12) {
                    ArtImage(source: library.artSource(p))
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                    Text(p.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    Text(summary(tracks)).font(.footnote).foregroundStyle(.secondary)
                    BusyLine()
                    if tracks.isEmpty {
                        if !p.origin.isEmpty {
                            Button("Загрузить треки по ссылке") { library.importLink(p.origin, into: pid) }
                                .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button("Добавить треки") { picking = true }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    } else {
                        PlayShuffleRow(ids: tracks.map(\.id), context: p.name)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t) { player.play(tracks.map(\.id), start: i, context: p.name) }
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowBackground(Color.clear)
                }
                .onDelete { library.removeFromPlaylist(pid, at: $0) }
                .onMove { library.movePlaylistTracks(pid, from: $0, to: $1) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
    }

    private func summary(_ t: [LTrack]) -> String {
        let n = t.count
        let total = t.reduce(0) { $0 + $1.duration }
        let srcs = Set(t.map(\.source)).map(\.title).sorted().joined(separator: ", ")
        var s = "\(n) \(plural(n, "трек", "трека", "треков"))"
        if total > 0 { s += " · \(Int((total / 60).rounded())) мин" }
        if !srcs.isEmpty { s += " · \(srcs)" }
        return s
    }
}

/// Выбор треков из библиотеки в плейлист
struct TrackPicker: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let pid: String
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            let have = Set(library.playlist(pid)?.trackIDs ?? [])
            let list = library.tracks.filter { !have.contains($0.id) }
            List {
                if list.isEmpty {
                    Text("Все треки уже в плейлисте. Новые добавляются во вкладке «Треки».").foregroundStyle(.secondary)
                }
                ForEach(list) { t in
                    TrackRow(track: t, selecting: true, selected: chosen.contains(t.id)) {
                        if chosen.contains(t.id) { chosen.remove(t.id) } else { chosen.insert(t.id) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .navigationTitle("Добавить треки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить (\(chosen.count))") {
                        library.addToPlaylist(pid, library.tracks.map(\.id).filter { chosen.contains($0) })
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
