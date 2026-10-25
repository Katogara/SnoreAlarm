import SwiftUI

/// 録音したいびきの一覧 (直近1週間)。アプリを終了してログが消えたあとも聞き直せる。
struct RecordingsView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(SnorePlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var recordings: [RecordingStore.Recording] = []

    var body: some View {
        NavigationStack {
            List {
                if monitor.isActive {
                    // 録音が多いとフッターは見えないため、先頭に出す
                    Section {
                        Label {
                            PhraseText("監視中は録音を再生できません (再生した音をいびきと誤検知しないため)。監視を終了すると再生できます。")
                        } icon: {
                            Image(systemName: "speaker.slash")
                        }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if recordings.isEmpty {
                        Text("録音したいびきはまだありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recordings) { recording in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recording.date.formatted(date: .abbreviated, time: .standard))
                                        .font(.subheadline.monospacedDigit())
                                    Text(String(format: "%.1f秒", recording.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                PlayButton(url: recording.url)
                                    .disabled(monitor.isActive)
                            }
                            PlaybackWaveform(url: recording.url)
                        }
                    }
                    .onDelete(perform: delete)
                } footer: {
                    PhraseText("再生中は波形を表示します (横が時間、上下が録音したままの音の大きさ)。録音は1週間で自動的に削除されます。左にスワイプすると削除できます。")
                }
            }
            .navigationTitle("録音したいびき")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task {
                recordings = RecordingStore.list().filter { Date().timeIntervalSince($0.date) <= RecordingStore.retention }
            }
            .onDisappear {
                player.stop()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            if player.playingURL == recordings[index].url {
                player.stop()
            }
            RecordingStore.delete(recordings[index])
        }
        recordings.remove(atOffsets: offsets)
    }
}

/// 録音の再生・停止ボタン
struct PlayButton: View {
    @Environment(SnorePlayer.self) private var player
    let url: URL

    var body: some View {
        let isPlaying = player.playingURL == url
        Button {
            player.toggle(url)
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.title2)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isPlaying ? "停止" : "再生")
    }
}
