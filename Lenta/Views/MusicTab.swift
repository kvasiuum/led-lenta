import SwiftUI
import UniformTypeIdentifiers

struct MusicTab: View {
    @EnvironmentObject var music: MusicModel

    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 16) {
                SegPicker(selection: $music.tab, items: MusicModel.Tab.allCases.map { ($0, $0.title) }, label: "Раздел музыки")

                Group {
                    switch music.tab {
                    case .tracks: TracksPanel()
                    case .playlists: PlaylistsPanel()
                    case .mic: MicArea()
                    }
                }
                .id(music.tab)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            .card()
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: music.tab)

            Button {
                Task { await player.startWave() }
            } label: {
                if player.loadingWave { ProgressView("Подбираю треки…") }
                else { Label("Моя волна", systemImage: "waveform") }
            }
            .buttonStyle(.bordered)
            .disabled(player.loadingWave)
            LightOptionsCard()
        }
    }
}

// MARK: - Треки

private struct TracksPanel: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @State private var importingFiles = false
    @State private var linkSheet = false
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    Button("Файлы с телефона", systemImage: "folder") { importingFiles = true }
                    Button("Ссылка: SoundCloud, Spotify, Яндекс", systemImage: "link") { linkSheet = true }
                } label: {
                    Label("Добавить", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Web.rBtn, style: .continuous))
                }
                Spacer()
                if !library.tracks.isEmpty {
                    Button(selecting ? "Готово" : "Выбрать") {
                        withAnimation(.snappy) { selecting.toggle(); selected = [] }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .webFill()
                    .buttonStyle(.plain)
                }
            }

            BusyLine()

            if library.tracks.isEmpty {
                Hint("Добавь свои файлы или ссылку на трек SoundCloud, Spotify или Яндекс Музыки. Из выбранных треков потом можно собрать плейлист.")
            } else {
                if !selecting {
                    PlayShuffleRow(ids: library.tracks.map(\.id), context: "Все треки")
                }
                LazyVStack(spacing: 2) {
                    ForEach(Array(library.tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t, selecting: selecting, selected: selected.contains(t.id)) {
                            if selecting { toggle(t.id) }
                            else { player.play(library.tracks.map(\.id), start: i, context: "Все треки") }
                        }
                        .contextMenu { if !selecting { rowMenu(t) } }
                        // долгое нажатие и перетаскивание — поменять порядок
                        .reorderable(id: t.id, target: $dropTarget) { library.moveTrack($0, to: t.id) }
                    }
                }
            }

            if library.tracks.count > 1 && !selecting {
                Hint("Зажми трек и перетащи, чтобы поменять порядок.")
            }

            if selecting && !selected.isEmpty {
                VStack(spacing: 8) {
                    Text("Выбрано: \(selected.count)").font(.footnote).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        Button { newName = ""; naming = true } label: {
                            Label("Новый плейлист", systemImage: "music.note.list").lineLimit(1)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Menu {
                            ForEach(library.playlists) { p in
                                Button(p.name) { library.addToPlaylist(p.id, ordered(selected)); done("Добавлено в «\(p.name)»") }
                            }
                        } label: {
                            Image(systemName: "text.badge.plus").frame(width: 44, height: 44).webFill()
                        }
                        .disabled(library.playlists.isEmpty)
                        .accessibilityLabel("Добавить в плейлист")
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Image(systemName: "trash").foregroundStyle(Web.bad).frame(width: 44, height: 44).webFill()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить выбранные")
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { library.addFiles(urls) }
        }
        .sheet(isPresented: $linkSheet) { AddLinkSheet(asPlaylist: false, into: nil) }
        .alert("Новый плейлист", isPresented: $naming) {
            TextField("Название", text: $newName)
            Button("Создать") {
                let p = library.createPlaylist(newName, ordered(selected))
                done("Плейлист «\(p.name)» создан")
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(selected.count) \(plural(selected.count, "трек", "трека", "треков"))")
        }
        .confirmationDialog("Удалить \(selected.count) \(plural(selected.count, "трек", "трека", "треков"))?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { library.removeTracks(selected); done("Удалено") }
        } message: {
            Text("Треки пропадут и из плейлистов.")
        }
    }

    @ViewBuilder
    private func rowMenu(_ t: LTrack) -> some View {
        Menu("В плейлист", systemImage: "text.badge.plus") {
            Button("Новый плейлист…", systemImage: "plus") { selected = [t.id]; newName = ""; naming = true }
            ForEach(library.playlists) { p in
                Button(p.name) { library.addToPlaylist(p.id, [t.id]); Services.shared.app.showToast("Добавлено в «\(p.name)»") }
            }
        }
        Button("В начало списка", systemImage: "arrow.up.to.line") { library.moveTrackToEdge(t.id, top: true) }
        Button("В конец списка", systemImage: "arrow.down.to.line") { library.moveTrackToEdge(t.id, top: false) }
        Button("Удалить", systemImage: "trash", role: .destructive) { library.removeTracks([t.id]) }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Выбранные — в порядке библиотеки
    private func ordered(_ set: Set<String>) -> [String] { library.tracks.map(\.id).filter { set.contains($0) } }

    private func done(_ msg: String) {
        Services.shared.app.showToast(msg)
        withAnimation(.snappy) { selecting = false; selected = [] }
    }
}

// MARK: - Плейлисты

private struct PID: Identifiable { let id: String }

private struct PlaylistsPanel: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @State private var linkSheet = false
    @State private var naming = false
    @State private var newName = ""
    @State private var open: PID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { linkSheet = true } label: { Label("Перенести по ссылке", systemImage: "link").lineLimit(1) }
                    .buttonStyle(PrimaryButtonStyle())
                Button { newName = ""; naming = true } label: { Image(systemName: "plus") }
                    .buttonStyle(RoundIconButtonStyle(size: 46))
                    .accessibilityLabel("Новый пустой плейлист")
            }

            BusyLine()

            if library.playlists.isEmpty {
                Hint("Собери плейлист из своих треков (Треки → Выбрать) или перенеси готовый из SoundCloud, Spotify или Яндекс Музыки по ссылке.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                    ForEach(library.playlists) { p in
                        Button { open = PID(id: p.id) } label: { PlaylistTile(p: p) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Слушать", systemImage: "play.fill") { listen(p, shuffled: false) }
                                Button("Перемешать", systemImage: "shuffle") { listen(p, shuffled: true) }
                                Button("Удалить плейлист", systemImage: "trash", role: .destructive) { library.deletePlaylist(p.id) }
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $linkSheet) { AddLinkSheet(asPlaylist: true, into: nil) }
        .sheet(item: $open) { PlaylistDetail(pid: $0.id) }
        .alert("Новый плейлист", isPresented: $naming) {
            TextField("Название", text: $newName)
            Button("Создать") { open = PID(id: library.createPlaylist(newName, []).id) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func listen(_ p: Playlist, shuffled: Bool) {
        let ids = library.tracks(of: p).map(\.id)
        guard !ids.isEmpty else {
            if !p.origin.isEmpty { library.importLink(p.origin, into: p.id) }
            return
        }
        if shuffled { player.playShuffled(ids, context: p.name) } else { player.play(ids, start: 0, context: p.name) }
    }
}

private struct PlaylistTile: View {
    @EnvironmentObject var library: LibraryStore
    let p: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SquareArt(source: library.artSource(p), radius: 16)
                .overlay(alignment: .bottomLeading) { sourceDots.padding(8) }
            Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(count).font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var count: String {
        let n = library.tracks(of: p).count
        if n == 0 { return p.origin.isEmpty ? "Пусто" : "Нажми, чтобы загрузить" }
        return "\(n) \(plural(n, "трек", "трека", "треков"))"
    }

    /// Из каких сервисов треки
    private var sourceDots: some View {
        let set = Set(library.tracks(of: p).map(\.source))
        return HStack(spacing: 3) {
            ForEach(TrackSource.allCases.filter { set.contains($0) }, id: \.self) { SourceBadge(source: $0) }
        }
    }
}

// MARK: - Микрофон

private struct MicArea: View {
    @EnvironmentObject var music: MusicModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { music.toggleMic() } label: {
                Label(music.micActive ? "Остановить" : "Слушать микрофон",
                      systemImage: music.micActive ? "stop.fill" : "mic.fill")
            }
            .buttonStyle(GlassButtonStyle(on: music.micActive, accent: Color(red: 1, green: 0.42, blue: 0.4)))
            Hint("Лента реагирует на звук в комнате: колонку, телевизор или музыку из этого же телефона — в том числе Spotify и Яндекс. Микрофон точнее ровного ритма встроенных плееров. Ничего не записывается.")
        }
    }
}

// MARK: - Как светиться

struct LightOptionsCard: View {
    @EnvironmentObject var light: LightEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("Как светиться")
            SegPicker(selection: $light.mode, items: LightEngine.Mode.allCases.map { ($0, $0.title) }, label: "Режим подсветки")

            SliderRow(label: "Чувствительность к биту", value: "\(Int(sensHz(light.sensValue))) Гц",
                      v: $light.sens, range: 1...10)
            SliderRow(label: "Плавность", value: "\(Int(light.smooth.rounded()))",
                      v: $light.smooth, range: 1...10)
            VStack(alignment: .leading, spacing: 4) {
                SliderRow(label: "Свет раньше на", value: "\(Int(light.leadMs)) мс",
                          v: $light.leadMs, range: 0...400, step: 10)
                Hint("Вспышки отстают от бочки — двигай вправо, опережают — влево. Для своих треков и SoundCloud; микрофон слышит звук только когда он уже прозвучал.")
            }
            LevelMeter()
            Toggle("Не гасить экран, пока работает светомузыка", isOn: $light.keepAwake)
                .tint(.green)
                .font(.subheadline)
        }
        .card()
    }
}
