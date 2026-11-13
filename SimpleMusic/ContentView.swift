import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = LibraryModel()
    @StateObject private var artwork: ArtworkModel
    @State private var knownArtworkTracks: Set<UUID> = []
    @StateObject private var preferences: PlaybackPreferences
    @StateObject private var player: MusicPlayer
    @StateObject private var normalization: NormalizationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAudioSettings = false
    @State private var showingPlaybackSettings = false
    @AppStorage(PlaybackRecovery.mixKey) private var mixAudio = true
    @State private var importing = false
    @State private var showingFailures = false
    @State private var showingHelp = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @State private var favoritesOnly = false
    @State private var searchText = ""
    @AppStorage("librarySort") private var sortValue = LibrarySort.addedOldest.rawValue
    @State private var displayedTracks: [Track] = []
    @State private var showingQueue = false
    @State private var showingBulkDeletion = false
    @State private var pendingDeletion: Track?
    @State private var showingLicenses = false
    @State private var showingMenu = false
    @State private var menuAction: AppMenuAction?
    @State private var showingBackup = false
    @State private var showingStatistics = false
    @State private var showingStorage = false
    @ObservedObject private var controlRequests = ControlRequests.shared
    @State private var startupComplete = false
    @State private var carResumeRequestedAt: Date?
    @State private var controlMessage = ""
    @State private var showingControlMessage = false

    init() {
        let preferences = PlaybackPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        let normalization = NormalizationModel()
        _normalization = StateObject(wrappedValue: normalization)
        let artwork = ArtworkModel()
        _artwork = StateObject(wrappedValue: artwork)
        _player = StateObject(wrappedValue: MusicPlayer(preferences: preferences, normalization: normalization, artwork: artwork))
    }

    private var visibleTracks: [Track] { displayedTracks }

    private func updateVisibleTracks() {
        displayedTracks = LibraryQuery.apply(library.tracks, search: searchText, favoritesOnly: favoritesOnly,
            favorites: preferences.state.favorites, counts: preferences.state.playCounts,
            sort: LibrarySort(rawValue: sortValue) ?? .addedOldest)
    }

    private var emptyLibrary: some View {
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = searching ? "検索結果がありません" : (favoritesOnly ? "お気に入りはまだありません" : "音楽を追加しましょう")
        let icon = searching ? "magnifyingglass" : (favoritesOnly ? "heart" : "music.note")
        let description = searching ? "曲名・アーティストや検索語を変えてください。" : (favoritesOnly ? "曲のハートを押すと追加できます。" : "右上の「…」→「音楽を取り込む」からファイルを選んでください。")
        return ContentUnavailableView(LocalizedStringKey(title), systemImage: icon, description: Text(description))
    }

    private var libraryList: some View {
        List {
            if library.busy { ProgressView("ファイルを確認しています…") }
            Section {
                Picker("表示する曲", selection: $favoritesOnly) {
                    Text("すべて").tag(false)
                    Text("お気に入り").tag(true)
                }.pickerStyle(.segmented)
                Picker("並び替え", selection: $sortValue) {
                    ForEach(LibrarySort.allCases) { order in Text(order.label).tag(order.rawValue) }
                }.pickerStyle(.menu).accessibilityIdentifier("library-sort")
                Button { player.shufflePlay(visibleTracks) } label: {
                    Label("少ない再生回数を優先してシャッフル", systemImage: "shuffle")
                }.disabled(visibleTracks.isEmpty || !preferences.ready)
                if !preferences.errorMessage.isEmpty {
                    Text(preferences.errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            Section("曲 \(visibleTracks.count)") {
                if visibleTracks.isEmpty {
                    emptyLibrary
                }
                ForEach(visibleTracks) { track in
                    HStack(spacing: 12) {
                        Button { player.play(track, in: visibleTracks) } label: {
                            HStack(spacing: 12) {
                            ArtworkThumbnail(artwork: artwork, track: track)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).lineLimit(2).foregroundStyle(.primary)
                                Text("\(track.artistLabel) · \(clockText(track.duration)) · 再生\(preferences.count(for: track))回")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            }
                            Spacer()
                            }
                        }.buttonStyle(.plain)
                        Button { preferences.toggleFavorite(track) } label: {
                            Image(systemName: preferences.isFavorite(track) ? "heart.fill" : "heart")
                                .foregroundStyle(preferences.isFavorite(track) ? .pink : .secondary)
                                .frame(minWidth: 32, minHeight: 44)
                        }.buttonStyle(.borderless).disabled(!preferences.ready)
                            .accessibilityLabel(preferences.isFavorite(track) ? "\(track.title)をお気に入りから外す" : "\(track.title)をお気に入りに追加")
                        Menu {
                            Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                player.enqueue(track, next: true)
                            }
                            Button("キューの最後に追加", systemImage: "text.badge.plus") {
                                player.enqueue(track)
                            }
                        } label: {
                            Image(systemName: "plus.circle").frame(minWidth: 32, minHeight: 44)
                        }
                        .disabled(player.current?.id == track.id)
                        .accessibilityLabel("\(track.title)をキューに追加")
                    }.buttonStyle(.borderless)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library-row-\(track.title)")
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDeletion = track } label: {
                            Label("削除", systemImage: "trash")
                        }.disabled(library.busy)
                            .accessibilityIdentifier("library-delete-\(track.title)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playerControls: some View {
                if let track = player.current {
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).font(.headline).lineLimit(1)
                                Text(track.artistLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { player.cycleRepeat() } label: {
                                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                                    .frame(minWidth: 32, minHeight: 44)
                            }.accessibilityLabel(player.repeatMode.label).accessibilityIdentifier("player-repeat")
                            Button { preferences.toggleFavorite(track) } label: {
                                Image(systemName: preferences.isFavorite(track) ? "heart.fill" : "heart")
                            }.disabled(!preferences.ready).accessibilityLabel("お気に入りを切り替え")
                            Button { showingQueue = true } label: { Image(systemName: "list.bullet") }
                                .accessibilityLabel("再生キュー")
                        }
                        if player.isPreparing { ProgressView("再生を準備しています…") }
                        Slider(value: Binding(get: { scrubbing ? scrub : player.position },
                            set: { scrub = $0; if !scrubbing { player.seek(to: $0) } }), in: 0...max(player.duration, 0.1),
                            onEditingChanged: { editing in
                                if editing { scrub = player.position }
                                scrubbing = editing
                                if !editing { player.seek(to: scrub) }
                            })
                            .accessibilityLabel("再生位置")
                        HStack {
                            Text(clockText(scrubbing ? scrub : player.position))
                            Spacer()
                            Text(clockText(player.duration))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            Button { player.shufflePlay(visibleTracks) } label: {
                                Image(systemName: "shuffle")
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.disabled(visibleTracks.isEmpty || !preferences.ready)
                                .accessibilityLabel("少ない再生回数を優先してシャッフル")
                                .accessibilityIdentifier("player-shuffle")
                            Button { player.previous() } label: {
                                Image(systemName: "backward.end.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }
                                .disabled(!player.canPrevious).accessibilityLabel("前の曲")
                            Button { player.toggle() } label: {
                                Image(systemName: (player.isPlaying || player.isPreparing) ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 42))
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.accessibilityLabel((player.isPlaying || player.isPreparing) ? "一時停止" : "再生")
                            Button { player.next() } label: {
                                Image(systemName: "forward.end.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }
                                .disabled(!player.canNext).accessibilityLabel("次の曲")
                            Button { player.stop() } label: {
                                Image(systemName: "stop.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }
                                .accessibilityLabel("停止")
                        }.buttonStyle(.plain).foregroundStyle(.tint)
                        if !player.errorMessage.isEmpty {
                            Text(player.errorMessage).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding().background(.regularMaterial)
                }
    }

    private var mainPage: some View {
        libraryList
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "曲名・アーティストを検索")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingQueue = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("再生キュー")
                    .accessibilityIdentifier("open-queue")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingMenu = true } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("メニュー")
            }
        }
        .safeAreaInset(edge: .bottom) { playerControls }
    }

    private var importPage: some View {
        mainPage
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .data],
            allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.message = "選択できません: \(error.localizedDescription)"
                }
            }
        .sheet(isPresented: $showingAudioSettings) {
            NormalizationSettingsView(normalization: normalization, tracks: library.tracks,
                busy: library.busy, onToggle: { player.updateNormalization() })
        }
        .sheet(isPresented: $showingPlaybackSettings) { PlaybackSettingsView(player: player) }
        .onChange(of: mixAudio) { _, _ in player.updateAudioMix() }
        .onChange(of: normalization.profiles) { _, _ in player.updateNormalization() }
        .onChange(of: artwork.revisions) { _, _ in player.updateArtwork() }
        .onChange(of: scenePhase) { _, value in if value != .active { normalization.cancelAnalysis(); artwork.cancel() } }
    }

    private var libraryDialogs: some View {
        importPage
        .sheet(isPresented: $showingMenu, onDismiss: performMenuAction) {
            AppMenuView(ready: library.ready, busy: library.busy, hasTracks: !library.tracks.isEmpty,
                message: library.message, hasFailures: !library.failures.isEmpty, artwork: artwork) { action in
                menuAction = action; showingMenu = false
            }
        }
        .sheet(isPresented: $showingStorage) { StorageDiagnosticsView(tracks: library.tracks) }
        .sheet(isPresented: $showingStatistics) { StatisticsView(tracks: library.tracks, preferences: preferences) }
        .sheet(isPresented: $showingBackup) {
            BackupView(library: library, preferences: preferences, player: player, normalization: normalization)
        }
        .sheet(isPresented: $showingBulkDeletion) {
            BulkDeletionView(library: library, player: player)
        }
        .sheet(isPresented: $showingFailures) {
            NavigationStack {
                List(library.failures, id: \.self) { Text($0) }
                    .navigationTitle("取り込み結果")
                    .toolbar { Button("閉じる") { showingFailures = false } }
            }
        }
        .sheet(isPresented: $showingQueue) {
            QueueView(player: player)
        }
        .confirmationDialog("この曲をアプリから削除しますか？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion) { track in
                Button("削除", role: .destructive) {
                    Task {
                        if player.current?.id == track.id { player.stop() }
                        if await library.delete(track) { player.forget(track) }
                        pendingDeletion = nil
                    }
                }.accessibilityIdentifier("confirm-library-delete")
                Button("キャンセル", role: .cancel) { pendingDeletion = nil }
            } message: { track in
                Text("「\(track.title)」のアプリ内コピー、お気に入り、再生回数を削除します。元の音楽ファイルは残ります。再生中の曲は停止します。")
            }
    }

    private func performMenuAction() {
        guard let action = menuAction else { return }
        menuAction = nil
        switch action {
        case .importMusic: importing = true
        case .failures: showingFailures = true
        case .storage: showingStorage = true
        case .statistics: player.refresh(); player.checkpoint(); showingStatistics = true
        case .artwork: artwork.acquire(library.tracks, retry: true)
        case .backup: showingBackup = true
        case .deletion: showingBulkDeletion = true
        case .playback: showingPlaybackSettings = true
        case .normalization: showingAudioSettings = true
        case .help: showingHelp = true
        case .licenses: showingLicenses = true
        case .demo:
            if let url = Bundle.main.url(forResource: "probe", withExtension: "wav") {
                Task { await library.importFiles([url]) }
            }
        }
    }

    private var presentedPage: some View {
        libraryDialogs
        .sheet(isPresented: $showingLicenses) {
            NavigationStack {
                ScrollView {
                    Text(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "ライセンスを読み取れません。")
                        .font(.caption).textSelection(.enabled).padding()
                }.navigationTitle("ライセンス")
                    .toolbar { Button("閉じる") { showingLicenses = false } }
            }
        }
        .sheet(isPresented: $showingHelp) {
            NavigationStack {
                List {
                    Section("取り込みと再生") {
                        Text("ファイル画面の「選択」から複数の音楽ファイルを選べます。曲名をタップすると再生し、一覧の順に次の曲へ進みます。")
                        Text("同じ内容の曲は重複追加しません。同じ名前でも内容が違えば追加します。元ファイルは変更しません。")
                        Text("クラウド上の曲は取り込み時にダウンロードが必要です。取り込み後はオフラインで利用できます。")
                        Text("再起動後も曲は残ります。アプリを削除すると取り込んだ曲も消えるため、元ファイルと設定のバックアップを別の保存先にも保管してください。今後の取り込みはFilesのSimpleMusic/Musicに保存し、従来の曲は元の専用領域に保持します。")
                    }
                    Section("お気に入り・キュー・シャッフル") {
                        Text("ハートでお気に入りを切り替えます。「お気に入り」表示中の再生やシャッフルは、その一覧の曲を対象にします。")
                        Text("＋から「次に再生」や「キューの最後に追加」を選べます。同じ曲はキュー内に1つだけ置き、追加済みなら移動します。曲名を押して再生すると一覧を新しいキューにします。")
                        Text("キュー画面の「編集」で矢印による順番変更・ごみ箱での削除ができます。編集が終わったら「完了」を押してください。選択中の曲はキューから削除できません。音楽ファイルは残ります。")
                        Text("再生回数が少ないほど選ばれやすいシャッフルです。確率の重みは1÷（再生回数＋1）で、キュー内で重複しません。実際に10秒以上、10秒未満の曲は最後まで再生すると1回加算します。シークで飛ばした時間は含めず、同じ再生の続きでは重複加算しません。従来の回数は保持します。")
                        Text("お気に入り・回数・キューと選択曲は保存します。開き直した直後は停止状態で、保存した再生位置から手動で再開できます。")
                        Text("リピートボタンでOFF→全曲→1曲を切り替えます。全曲＋優先シャッフルは周回ごとに最新の回数で順番を作り直します。2曲以上なら周回の境目で同じ曲を続けません。1曲モードでも手動の前後操作は可能です。")
                    }
                    Section("削除とOpus") {
                        Text("曲一覧を右へスワイプして「削除」を押すと、確認後にアプリ内の曲を削除します。右上メニューの「曲をまとめて削除」で複数選択や全選択もできます。元ファイルは残ります。再生中の曲を削除すると停止し、キュー・お気に入り・回数からも外します。")
                        Text("Ogg OpusとOgg Vorbisは元の圧縮形式で保存します。Opusは標準APIを優先し、指定位置再生では公式デコーダを使います。Vorbisと音量補正時は少しずつPCMを読み取ります。WAVの作成や再圧縮はしません。専用デコーダはモノラル／ステレオ・単一ストリームを対象にします。動画再生は対応しません。")
                        Text("旧版で取り込んだOpusはWAVのまま再生できます。元のOpusをもう一度取り込むと、曲ID・お気に入り・回数を保ち圧縮ファイルへ置き換えます。元ファイルなしにWAVからOpusを復元することはできません。")
                    }
                    Section("専用コントロールの動作確認") {
                        if let date = controlRequests.lastAppIntentDate {
                            Text("アプリ起動要求の最終受信: \(date.formatted(date: .numeric, time: .standard))")
                        } else {
                            Text("アプリ起動要求: 未受信")
                        }
                        Text("専用コントロールを押した後、この時刻が更新されるか確認できます。URLを開く従来のショートカットでは更新しません。時刻は再生成功を示すものではありません。")
                            .font(.caption)
                    }
                    Section("0.9.8の対応状況") {
                        if !player.backendLabel.isEmpty {
                            Text("再生方式: \(player.backendLabel)")
                            if !player.nativeDiagnostic.isEmpty { Text(player.nativeDiagnostic).font(.caption) }
                        }
                        Text("MP3・AAC（M4A/ADTS）・FLAC・WAV・Ogg Opus・Ogg Vorbisを対象にしています。読めないファイルはエラーを表示します。")
                        Text("画面を閉じても再生を続け、ロック画面やコントロールセンターから再生・一時停止・前後の曲・再生位置を操作できます。アプリを強制終了すると再生は止まります。")
                        Text("アーティストタグを読み取り、ない場合は「不明なアーティスト」と表示します。曲名・アーティスト検索と並び替えに対応します。メニューの「音量正規化」から解析と補正を切り替えられます。")
                    }
                }
                .navigationTitle("使い方")
                .toolbar { Button("閉じる") { showingHelp = false } }
            }
        }
    }

    private var observedPage: some View {
            presentedPage
            .onChange(of: library.tracks) { _, tracks in
                let newTracks = tracks.filter { !knownArtworkTracks.contains($0.id) }
                knownArtworkTracks = Set(tracks.map(\.id))
                if library.ready { artwork.acquire(newTracks) }
                do {
                    if try preferences.applyPendingRestore(tracks) { player.adoptRestoredState(from: tracks, pause: false) }
                } catch { library.message = "復元情報を反映できません: \(error.localizedDescription)" }
                updateVisibleTracks()
                player.synchronizeLibrary(tracks)
            }
            .onChange(of: searchText) { _, _ in updateVisibleTracks() }
            .onChange(of: sortValue) { _, _ in updateVisibleTracks() }
            .onChange(of: favoritesOnly) { _, _ in updateVisibleTracks() }
            .onChange(of: preferences.state.favorites) { _, _ in updateVisibleTracks() }
            .onChange(of: preferences.state.playCounts) { _, _ in updateVisibleTracks() }
    }

    var body: some View {
        NavigationStack {
            observedPage
            .onChange(of: controlRequests.generation) { _, _ in processControlShuffle() }
            .onChange(of: library.busy) { _, busy in
                if !busy { processControlShuffle(); processCarResume() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { processControlShuffle(); processCarResume() }
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "simplemusic",
                      url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return }
                switch url.host?.lowercased() {
                case "shuffle": controlRequests.submit(); processControlShuffle()
                case "resume": carResumeRequestedAt = Date(); processCarResume()
                default: break
                }
            }
            .alert("シャッフル再生", isPresented: $showingControlMessage) { Button("閉じる", role: .cancel) {} }
                message: { Text(controlMessage) }
            .task { await loadAndRefresh() }
        }
    }

    @MainActor
    private func processControlShuffle() {
        guard startupComplete, scenePhase == .active, !library.busy else { return }
        guard controlRequests.consume() else { return }
        guard library.ready, preferences.ready else {
            controlMessage = "曲一覧・再生設定を読み取れないため再生を開始できません。保存データは変更していません。"
            showingControlMessage = true; return
        }
        let tracks = ControlShufflePolicy.targets(library: library.tracks, queue: player.queue)
        guard !tracks.isEmpty else {
            controlMessage = "音楽がまだありません。右上のメニューから音楽を取り込んでください。"
            showingControlMessage = true; return
        }
        player.shufflePlay(tracks)
    }

    @MainActor
    private func processCarResume() {
        guard startupComplete, scenePhase == .active, !library.busy,
              let requestedAt = carResumeRequestedAt else { return }
        carResumeRequestedAt = nil
        guard Date().timeIntervalSince(requestedAt) < 30, library.ready, preferences.ready else { return }
        player.resumeForCar()
    }

    @MainActor
    private func loadAndRefresh() async {
        await library.load()
        knownArtworkTracks = Set(library.tracks.map(\.id))
        if library.ready {
            do {
                try preferences.applyPendingRestore(library.tracks)
                try preferences.applyRestoredSettings(normalization: normalization)
            } catch { library.message = "復元情報を反映できません: \(error.localizedDescription)" }
            preferences.reconcileLibrary(library.tracks)
            player.restoreQueue(from: library.tracks)
        }
        if ProcessInfo.processInfo.arguments.contains("-ci-seed-library"),
           let url = Bundle.main.url(forResource: "probe", withExtension: "wav") {
            await library.importFiles([url])
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-library"),
           let probe = Bundle.main.url(forResource: "probe", withExtension: "wav") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                var urls: [URL] = []
                for index in 1...3 {
                    var data = try Data(contentsOf: probe)
                    data[data.count - 1] ^= UInt8(index)
                    let url = temporary.appendingPathComponent("UI曲\(index).wav")
                    try data.write(to: url)
                    urls.append(url)
                }
                await library.importFiles(urls)
                let tracks = library.tracks.filter { $0.title.hasPrefix("UI曲") }
                if let first = tracks.first, !ProcessInfo.processInfo.arguments.contains("-ui-test-preserve-position") {
                    player.play(first, in: tracks)
                    player.pause()
                }
            } catch { library.message = error.localizedDescription }
            try? FileManager.default.removeItem(at: temporary)
        }
        startupComplete = true
        processControlShuffle()
        processCarResume()
    }
}

