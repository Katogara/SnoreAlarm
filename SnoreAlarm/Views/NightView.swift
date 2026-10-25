import Charts
import SwiftUI

/// 一晩のいびきの記録。横が時刻、縦が録音したいびきの大きさ (録音したままの音量、-60〜0 dB)。
/// 監視していた時間帯を帯で示し、グラフに触れると近くのいびきを選んで再生できる。
struct NightView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(SnorePlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AlarmSettings.Key.dayBoundaryMinutes) private var boundaryMinutes = AlarmSettings.Default.dayBoundaryMinutes

    @State private var nights: [NightRecord] = []
    @State private var index = 0
    /// 最大音量をファイル名に持たない (以前の版の) 録音の最大音量
    @State private var measuredPeaks: [URL: Float] = [:]
    @State private var selectedURL: URL?
    @State private var touchedDate: Date?
    @State private var loaded = false
    /// グラフに表示している時間の幅 (秒)。nil なら一晩全体
    @State private var visibleLength: TimeInterval?
    /// グラフの左端の時刻 (拡大しているときに左右へスクロールした位置)
    @State private var scrollPosition = Date()
    /// ピンチを始めたときの表示の幅
    @State private var pinchStartLength: TimeInterval?

    /// 拡大できる上限 (この幅の時間まで広げる)
    static let minVisibleLength: TimeInterval = 3 * 60

    private struct Point: Identifiable {
        let recording: RecordingStore.Recording
        let db: Double
        var id: URL { recording.url }
    }

    var body: some View {
        NavigationStack {
            List {
                if nights.indices.contains(index) {
                    let night = nights[index]
                    let points = points(of: night)
                    Section {
                        header(of: night)
                    }
                    Section {
                        chart(of: night, points: points)
                            .padding(.top, 8)
                        zoomControls(of: night)
                    } footer: {
                        PhraseText("横が時刻、縦が録音したいびきの大きさ (録音したままの音量) です。色の付いた帯は監視していた時間、オレンジの点線は振動で知らせた時刻です。ピンチで拡大・縮小し、拡大中は左右にスクロールできます。グラフをタップすると、近くのいびきを選んで波形の確認と再生ができます。いびきの録音をオフにしていた間のいびきは表示されません。")
                    }
                    if let selected = night.recordings.first(where: { $0.url == selectedURL }) {
                        selectedSection(selected, in: night)
                    }
                    summarySection(of: night, points: points)
                    if !night.alarms.isEmpty {
                        alarmSection(of: night)
                    }
                } else if loaded {
                    Section {
                        PhraseText("記録はまだありません。監視を開始していびきを録音すると、一晩ごとのグラフをここに表示します (録音と同じく1週間残ります)。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("一晩の記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task(id: boundaryMinutes) {
                await reload()
            }
            .onChange(of: index) {
                selectedURL = nil
                player.stop()
                resetZoom()
            }
            .onDisappear {
                player.stop()
            }
        }
    }

    // MARK: - 表示

    private func header(of night: NightRecord) -> some View {
        HStack {
            Button {
                index += 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(index + 1 >= nights.count)
            .accessibilityLabel("前の夜")

            Spacer()
            VStack(spacing: 2) {
                Text(night.dayStart.formatted(.dateTime.month().day().weekday()))
                    .font(.headline)
                Text("\(night.start.formatted(date: .omitted, time: .shortened)) 〜 \(night.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                index -= 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .accessibilityLabel("次の夜")
        }
    }

    private func chart(of night: NightRecord, points: [Point]) -> some View {
        let length = visibleLength(of: night)
        return Chart {
            ForEach(night.periods, id: \.self) { period in
                RectangleMark(xStart: .value("開始", period.start), xEnd: .value("終了", period.end),
                              yStart: .value("音量", Double(Waveform.floorDB)), yEnd: .value("音量", 0.0))
                    .foregroundStyle(Color.teal.opacity(0.12))
            }
            ForEach(points) { point in
                let isSelected = point.id == selectedURL
                RuleMark(x: .value("時刻", point.recording.date),
                         yStart: .value("音量", Double(Waveform.floorDB)), yEnd: .value("音量", point.db))
                    .foregroundStyle(isSelected ? Color.orange : Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: isSelected ? 3 : 1.5))
            }
            ForEach(night.alarms, id: \.self) { alarm in
                RuleMark(x: .value("振動", alarm.date))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .chartXScale(domain: night.start...night.end)
        .chartYScale(domain: Double(Waveform.floorDB)...0)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: length)
        .chartScrollPosition(x: $scrollPosition)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: Self.axisStrideMinutes(for: length))) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [-60.0, -40, -20, 0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let db = value.as(Double.self) {
                        Text("\(Int(db))")
                    }
                }
            }
        }
        .chartYAxisLabel("dB", position: .leading)
        .chartXSelection(value: $touchedDate)
        // スクロールできるグラフでは、選択が長押しになるため、タップでも選べるようにする
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { value in
                proxy.selectXValue(at: value.location.x)
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchStartLength ?? length
                    pinchStartLength = base
                    zoom(to: base / value.magnification, in: night)
                }
                .onEnded { _ in
                    pinchStartLength = nil
                }
        )
        .onChange(of: touchedDate) {
            guard let touchedDate else { return }
            let nearest = points.min {
                abs($0.recording.date.timeIntervalSince(touchedDate)) < abs($1.recording.date.timeIntervalSince(touchedDate))
            }
            if let nearest, nearest.id != selectedURL {
                selectedURL = nearest.id
            }
        }
        .frame(height: 240)
        .accessibilityLabel("一晩のいびきのグラフ")
    }

    private func selectedSection(_ recording: RecordingStore.Recording, in night: NightRecord) -> some View {
        let position = night.recordings.firstIndex(of: recording) ?? 0
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.date.formatted(date: .omitted, time: .standard))
                            .font(.subheadline.monospacedDigit())
                        Text(detail(of: recording))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        select(night.recordings[position - 1], in: night)
                    } label: {
                        Image(systemName: "chevron.left.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(position == 0)
                    .accessibilityLabel("前のいびき")
                    Button {
                        select(night.recordings[position + 1], in: night)
                    } label: {
                        Image(systemName: "chevron.right.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(position + 1 >= night.recordings.count)
                    .accessibilityLabel("次のいびき")
                    PlayButton(url: recording.url)
                        .disabled(monitor.isActive)
                }
                PlaybackWaveform(url: recording.url)
                    .frame(minHeight: 84)
            }
            // 選んだ時点で波形を出す (再生しなくても音の大小が分かるように)。
            // 波形がまだないと PlaybackWaveform は中身が空で task が始まらないため、常に表示されている VStack に付ける
            .task(id: recording.url) {
                await player.showWaveform(of: recording.url)
            }
        } header: {
            Text("選んだいびき (\(position + 1) / \(night.recordings.count))")
        } footer: {
            if monitor.isActive {
                PhraseText("監視中は再生できません (再生した音をいびきと誤検知しないため)。")
            }
        }
    }

    private func summarySection(of night: NightRecord, points: [Point]) -> some View {
        Section {
            if night.hasMonitoringRecord {
                LabeledContent("監視していた時間",
                               value: night.periods.count > 1
                                   ? "\(durationText(night.monitoredDuration)) (\(night.periods.count)回)"
                                   : durationText(night.monitoredDuration))
            } else {
                LabeledContent("監視していた時間", value: "記録なし")
            }
            LabeledContent("いびき (録音した回数)", value: "\(night.recordings.count) 回")
            if night.hasMonitoringRecord && night.monitoredDuration >= 10 * 60 {
                LabeledContent("1時間あたり",
                               value: String(format: "%.1f 回", Double(night.recordings.count) / (night.monitoredDuration / 3600)))
            }
            LabeledContent("いびきの合計", value: snoreTotalText(night.snoreDuration))
            if let loudest = points.max(by: { $0.db < $1.db }) {
                LabeledContent("最大の音量",
                               value: String(format: "%.0f dB", loudest.db)
                                   + " (\(loudest.recording.date.formatted(date: .omitted, time: .shortened)))")
            }
            if let busiest = busiestHour(of: night) {
                LabeledContent("多かった時間帯", value: "\(busiest.hour)時台 (\(busiest.count)回)")
            }
            LabeledContent("振動で知らせた回数", value: "\(night.alarms.count) 回")
            if !night.alarms.isEmpty {
                LabeledContent("自分で止めた回数", value: "\(night.alarms.filter(\.stopped).count) 回")
            }
        } header: {
            Text("まとめ")
        } footer: {
            if !night.hasMonitoringRecord {
                PhraseText("この夜は、監視した時間を記録する前の版で録音したため、監視していた時間がありません。")
            }
        }
    }

    /// 振動で知らせた時刻と、どの端末で知らせたか
    private func alarmSection(of night: NightRecord) -> some View {
        Section("振動で知らせた時刻") {
            ForEach(night.alarms, id: \.self) { alarm in
                HStack {
                    Text(alarm.date.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                    PhraseText(deviceText(of: alarm.device))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if alarm.stopped {
                        Text("自分で止めた")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func deviceText(of device: AlarmEventStore.Event.Device) -> String {
        switch device {
        case .iPhone: "iPhone の振動"
        case .watch: "Apple Watch の振動"
        case .both: "Apple Watch と iPhone の振動"
        }
    }

    private func zoomControls(of night: NightRecord) -> some View {
        let span = night.end.timeIntervalSince(night.start)
        let length = visibleLength(of: night)
        return HStack(spacing: 16) {
            Button {
                zoom(to: length * 2, in: night)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(length >= span)
            .accessibilityLabel("縮小")
            Button {
                zoom(to: length / 2, in: night)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(length <= min(Self.minVisibleLength, span))
            .accessibilityLabel("拡大")
            Spacer()
            Text(length >= span ? "一晩全体" : "\(durationText(length)) の範囲")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("全体") {
                resetZoom()
            }
            .disabled(length >= span)
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    // MARK: - 拡大・スクロール

    private func visibleLength(of night: NightRecord) -> TimeInterval {
        let span = night.end.timeIntervalSince(night.start)
        return min(visibleLength ?? span, span)
    }

    /// 表示の中央を保ったまま、表示する時間の幅を変える
    private func zoom(to newLength: TimeInterval, in night: NightRecord) {
        let span = night.end.timeIntervalSince(night.start)
        let current = visibleLength(of: night)
        let length = min(max(newLength, min(Self.minVisibleLength, span)), span)
        let center = scrollPosition.addingTimeInterval(current / 2)
        visibleLength = length >= span ? nil : length
        scrollPosition = clampedScrollPosition(center.addingTimeInterval(-length / 2), length: length, in: night)
    }

    private func resetZoom() {
        visibleLength = nil
        pinchStartLength = nil
        if nights.indices.contains(index) {
            scrollPosition = nights[index].start
        }
    }

    /// `date` が表示の外なら、中央に来るようにスクロールする
    private func scroll(toShow date: Date, in night: NightRecord) {
        let length = visibleLength(of: night)
        guard date < scrollPosition || date > scrollPosition.addingTimeInterval(length) else { return }
        scrollPosition = clampedScrollPosition(date.addingTimeInterval(-length / 2), length: length, in: night)
    }

    private func clampedScrollPosition(_ date: Date, length: TimeInterval, in night: NightRecord) -> Date {
        min(max(date, night.start), night.end.addingTimeInterval(-length))
    }

    /// 表示の幅に合わせた横軸の目盛りの間隔 (分)。目盛りが 6 本程度になるようにする
    static func axisStrideMinutes(for length: TimeInterval) -> Int {
        let minutes = length / 60
        return [1, 2, 5, 10, 15, 30, 60, 120, 180].first { minutes / Double($0) <= 6 } ?? 240
    }

    // MARK: - データ

    private func reload() async {
        let recordings = RecordingStore.list().filter { Date().timeIntervalSince($0.date) <= RecordingStore.retention }
        let previousDay = nights.indices.contains(index) ? nights[index].dayStart : nil
        nights = NightRecord.nights(sessions: MonitoringSessionStore.load(), recordings: recordings,
                                    alarms: AlarmEventStore.load(), boundaryMinutes: boundaryMinutes,
                                    isMonitoring: monitor.isActive && !monitor.isDemo)
        index = nights.firstIndex { $0.dayStart == previousDay } ?? 0
        if nights.indices.contains(index) && nights[index].dayStart != previousDay {
            resetZoom()
        }
        loaded = true

        let missing = recordings.filter { $0.peakDB == nil && measuredPeaks[$0.url] == nil }.map(\.url)
        guard !missing.isEmpty else { return }
        let measured = await Task.detached(priority: .utility) {
            var result: [URL: Float] = [:]
            for url in missing {
                if let peak = RecordingStore.measurePeakDB(url) {
                    result[url] = peak
                }
            }
            return result
        }.value
        measuredPeaks.merge(measured) { $1 }
    }

    private func points(of night: NightRecord) -> [Point] {
        night.recordings.compactMap { recording in
            guard let peak = recording.peakDB ?? measuredPeaks[recording.url] else { return nil }
            return Point(recording: recording, db: min(max(Double(peak), Double(Waveform.floorDB)), 0))
        }
    }

    private func select(_ recording: RecordingStore.Recording, in night: NightRecord) {
        if player.playingURL != nil {
            player.stop()
        }
        selectedURL = recording.url
        scroll(toShow: recording.date, in: night)
    }

    private func detail(of recording: RecordingStore.Recording) -> String {
        let duration = String(format: "%.1f秒", recording.duration)
        guard let peak = recording.peakDB ?? measuredPeaks[recording.url], peak.isFinite else { return duration }
        return duration + String(format: "・最大 %.0f dB", peak)
    }

    private func busiestHour(of night: NightRecord) -> (hour: Int, count: Int)? {
        let counts = Dictionary(grouping: night.recordings) { Calendar.current.component(.hour, from: $0.date) }
            .mapValues(\.count)
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else {
            return nil
        }
        return (best.key, best.value)
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }

    private func snoreTotalText(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒"
    }
}
