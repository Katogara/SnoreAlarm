import Foundation
import SwiftUI
import UIKit

/// 開発中の不具合調査用の診断ログ。画面ロック中に何が起きていたか (マイク入力・オーディオの中断・
/// 経路の変更・アプリの状態・いびき判定の内訳) をファイルに残し、設定画面から書き出して共有できる。
///
/// コンパイル条件 `DIAGNOSTICS` (project.yml の SWIFT_ACTIVE_COMPILATION_CONDITIONS) のときだけ動く。
/// **リリース時は project.yml からその 1 行を消す**と、ログを書かず、設定画面の項目も出なくなる。
enum DiagnosticLog {
    #if DIAGNOSTICS
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    /// 1 ファイルの上限。超えたら 1 世代だけ残して新しいファイルに切り替える
    static let maxFileSize = 3 * 1024 * 1024

    static var fileURL: URL { directory.appendingPathComponent("diagnostics.log") }
    private static var previousFileURL: URL { directory.appendingPathComponent("diagnostics-previous.log") }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static let queue = DispatchQueue(label: "DiagnosticLog", qos: .utility)
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// どのスレッドからでも呼べる (書き込みは専用のキューで行う)
    static func write(_ message: @autoclosure () -> String) {
        #if DIAGNOSTICS
        let date = Date()
        let message = message()
        queue.async {
            append("\(formatter.string(from: date)) \(message)\n")
        }
        #endif
    }

    /// 端末・設定の情報を先頭に付けて、前の世代と合わせた 1 つのテキストファイルを作る
    static func export() async -> URL? {
        let header = await MainActor.run { headerText() }
        return await withCheckedContinuation { continuation in
            queue.async {
                var text = header
                for url in [previousFileURL, fileURL] {
                    if let data = try? Data(contentsOf: url), let log = String(data: data, encoding: .utf8) {
                        text += log
                    }
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnoreAlarm-diagnostics.txt")
                continuation.resume(returning: (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil)
            }
        }
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: previousFileURL)
        }
    }

    /// ログの合計サイズ (バイト)
    static func size() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                let total = [fileURL, previousFileURL].reduce(0) { sum, url in
                    sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
                }
                continuation.resume(returning: total)
            }
        }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        let url = fileURL
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // 画面ロック中も書けるようにする (最初のロック解除のあとは書ける)
            manager.createFile(atPath: url.path, contents: nil,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } else if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxFileSize {
            try? manager.removeItem(at: previousFileURL)
            try? manager.moveItem(at: url, to: previousFileURL)
            append(line)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    @MainActor
    private static func headerText() -> String {
        let info = Bundle.main.infoDictionary
        let settings = AlarmSettings.load()
        let config = settings.detectorConfig
        return """
        === SnoreAlarm diagnostics ===
        exported: \(formatter.string(from: Date())) (\(TimeZone.current.identifier))
        app: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))
        device: \(machineName()) iOS \(UIDevice.current.systemVersion)
        settings: alertDevice=\(settings.alertDevice.rawValue) required=\(config.requiredSnores) window=\(Int(config.windowSeconds))s \
        vibration=\(settings.vibrationSeconds)s delay=\(settings.startDelayMinutes)min record=\(settings.recordSnores) \
        margin=\(config.marginDB)dB minRatio=\(config.minLowBandRatio) schedule=\(settings.schedule.isEnabled)
        ==============================

        """
    }

    private static func machineName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

#if DIAGNOSTICS
/// 設定画面の「診断 (開発用)」。ログを書き出して共有する
struct DiagnosticsSection: View {
    @State private var exportURL: URL?
    @State private var size = 0

    var body: some View {
        Section {
            Button("診断ログを書き出す") {
                Task {
                    exportURL = await DiagnosticLog.export()
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("書き出したログを共有", systemImage: "square.and.arrow.up")
                }
            }
            Button("診断ログを消去", role: .destructive) {
                DiagnosticLog.clear()
                exportURL = nil
                size = 0
            }
        } header: {
            Text("診断 (開発用)")
        } footer: {
            PhraseText("不具合の調査用に、監視中の様子 (マイク入力・中断・画面ロック・いびき判定の内訳) を記録しています。録音した音そのものは含みません。現在 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))。この項目はリリース版では表示されません。")
        }
        .task {
            size = await DiagnosticLog.size()
        }
    }
}
#endif
