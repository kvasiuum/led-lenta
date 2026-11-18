import SwiftUI
import UniformTypeIdentifiers

struct MusicTab: View {
    @EnvironmentObject var music: MusicModel

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Источник звука", selection: $music.source) {
                    ForEach(MusicModel.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Group {
                    switch music.source {
                    case .file: FileArea()
                    case .sc: SoundCloudArea()
                    case .mic: MicArea()
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
                .id(music.source)
            }
            .card()
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: music.source)

            LightOptionsCard()
        }
    }
}

// MARK: - Свои треки

private struct FileArea: View {
    @EnvironmentObject var library: LocalLibrary
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { importing = true } label: {
                Label("Добавить музыку", systemImage: "plus")
            }
            .buttonStyle(GlassButtonStyle())

            if !library.tracks.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(library.tracks.enumerated()), id: \.element.id) { i, t in
                        let cur = i == library.cur
                        HStack(spacing: 12) {
                            Button { library.play(i) } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        ArtThumb(source: .file(library.artURL(t)), size: 40, radius: 8)
                                        if cur && library.isPlaying {
                                            Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 8))
                                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(width: 40, height: 40)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.displayTitle).lineLimit(1).fontWeight(cur ? .semibold : .regular)
                                        if let a = t.artist {
                                            Text(a).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button { withAnimation { library.remove(i) } } label: {
                                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Удалить \(t.displayTitle)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(cur ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                Hint("Треки хранятся в приложении и остаются после перезапуска. Файлы из «Файлов», AirDrop, iCloud Drive.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.add(urls: urls) }
        }
    }
}

// MARK: - SoundCloud

private struct SoundCloudArea: View {
    @EnvironmentObject var sc: SoundCloudController
    @EnvironmentObject var player: PlayerController
    @State private var link = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Ссылка на альбом, плейлист или трек", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(add)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .glass(in: Capsule())
                if link.isEmpty {
                    Button {
                        if let t = UIPasteboard.general.string { link = t; add() }
                    } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(RoundIconButtonStyle(size: 46))
                    .accessibilityLabel("Вставить ссылку")
                } else {
                    Button("Добавить", action: add).buttonStyle(PrimaryButtonStyle()).fixedSize()
                }
            }
            Hint("В SoundCloud: «Поделиться» → «Копировать ссылку». Закрытый плейлист добавляется по секретной ссылке.")

            if !sc.lib.isEmpty {
                Text("Мои плейлисты").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(sc.lib) { it in
                            LibTile(item: it, current: it.url == sc.url)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !sc.url.isEmpty { NowPlaylist() }

            Button(sc.showWidget ? "Скрыть плеер SoundCloud" : "Показать плеер SoundCloud") {
                sc.userShown = !sc.showWidget
                withAnimation { sc.showWidget.toggle() }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .opacity(sc.url.isEmpty ? 0 : 1)
        }
    }

    private func add() {
        let t = link
        link = ""
        focused = false
        sc.add(text: t)
    }
}

private struct LibTile: View {
    @EnvironmentObject var sc: SoundCloudController
    let item: SCLibItem
    let current: Bool

    var body: some View {
        Button { sc.open(item.url, autoplay: true) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtThumb(source: .web(item.art), size: 104, radius: 14)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(current ? Color.white : Color.clear, lineWidth: 2))
                Text(item.title).font(.caption.weight(.medium)).lineLimit(2).frame(width: 104, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { withAnimation { sc.removeFromLib(item.url) } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(5)
            .accessibilityLabel("Убрать «\(item.title)»")
        }
        .contextMenu {
            Button("Убрать", systemImage: "trash", role: .destructive) { sc.removeFromLib(item.url) }
        }
    }
}

private struct NowPlaylist: View {
    @EnvironmentObject var sc: SoundCloudController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ArtThumb(source: .web(sc.cover.isEmpty ? art300(sc.sounds.first?.artwork ?? "") : sc.cover),
                         size: 92, radius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(sc.title.isEmpty ? "Плейлист" : sc.title).font(.headline).lineLimit(2)
                    Text(sc.subtitle).font(.footnote).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        Button { sc.toggle() } label: {
                            Label(sc.playing ? "Пауза" : "Слушать", systemImage: sc.playing ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!sc.has)
                        Button { sc.shufflePlay() } label: { Image(systemName: "shuffle") }
                            .buttonStyle(RoundIconButtonStyle(size: 46))
                            .disabled(!sc.has)
                            .accessibilityLabel("Перемешать и слушать")
                    }
                    .padding(.top, 4)
                }
            }

            if !sc.waveNote.isEmpty { Hint(sc.waveNote) }

            LazyVStack(spacing: 2) {
                ForEach(Array(sc.sounds.enumerated()), id: \.offset) { i, s in
                    SoundRow(i: i, sound: s)
                }
            }
        }
        .padding(.top, 6)
    }
}

private struct SoundRow: View {
    @EnvironmentObject var sc: SoundCloudController
    let i: Int
    let sound: SCSound

    var body: some View {
        let cur = i == sc.index
        Button { sc.tapTrack(i) } label: {
            HStack(spacing: 12) {
                ZStack {
                    ArtThumb(source: .web(sound.artwork), size: 44, radius: 8)
                    if cur {
                        Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 8))
                        if sc.playing {
                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                        } else {
                            Image(systemName: "pause.fill").font(.footnote)
                        }
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sound.title.isEmpty ? "Загрузка…" : sound.title)
                        .lineLimit(1)
                        .fontWeight(cur ? .semibold : .regular)
                    Text(sound.user).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(sound.dur > 0 ? fmtTime(sound.dur / 1000) : "")
                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(cur ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Hint("Лента реагирует на звук в комнате: колонку, телевизор или музыку из другого приложения на этом телефоне. Ничего не записывается.")
        }
    }
}

// MARK: - Как светиться

struct LightOptionsCard: View {
    @EnvironmentObject var light: LightEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("Как светиться")
            Picker("Режим подсветки", selection: $light.mode) {
                ForEach(LightEngine.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            SliderRow(label: "Чувствительность к биту", value: "\(Int(sensHz(light.sensValue))) Гц",
                      v: $light.sens, range: 1...10)
            SliderRow(label: "Плавность", value: "\(Int(light.smooth.rounded()))",
                      v: $light.smooth, range: 1...10)
            LevelMeter()
            Toggle("Не гасить экран, пока работает светомузыка", isOn: $light.keepAwake)
                .tint(.green)
                .font(.subheadline)
        }
        .card()
    }
}
