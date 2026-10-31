# 引き継ぎメモ: いびきアラーム (SnoreAlarm)

最終更新: 2026-10-25

仕様書 (Claude Docs): https://claude.ai/artifact/Fh8ik4ETS1jeA9dCtRzKSZ  
機能の状態、検討した内容、次の作業は仕様書にまとめている。新しいセッションでは仕様書を読んでから続ける。

## 1. 要件

| 項目 | 内容 |
| --- | --- |
| 目的 | 睡眠中のいびきを iPhone のマイクで検知し、バイブレーションで本人に知らせて寝返り・起床を促す |
| 対象端末 | iPhone (iOS 17 以降)。実機のみ (シミュレータではマイク・振動を確認できない) |
| 必須動作 | 画面ロック中も検知を続ける / 一定時間内に規定回数のいびきで振動 |
| プライバシー | 音声は端末内でリアルタイム解析。いびきと判定した数秒間だけを端末内に録音し (設定でオフ可)、1 週間で自動削除。送信はしない |
| 設定項目 | 感度 (高/中/低)、回数 (2〜10)、判定時間 (30秒〜3分)、振動の長さ (3〜60秒)、開始までの待ち時間 (0〜60分)、録音のオン/オフ、寝る時刻のお知らせ・自動終了の時刻、一晩の記録の区切り |
| 開始忘れの防止 | 毎日決まった時刻に監視の開始を通知でお知らせし (通知から 1 タップで開始)、朝は自動で監視を終了する。待機中にマイクを使い続ける方式は不可 (イヤホンマイクが使えない・マイク使用中の表示が終日点くため) |
| 一晩の記録 | 1日の区切り (初期値 12:00、変更可) で一晩をまとめ、最初の開始から最後の終了までを 時刻 × いびきの音量 のグラフで表示する |
| ユーザー環境の制約 | **Mac を持っていない (Windows のみ)**。ビルドは GitHub Actions の macOS ランナー、インストールは Windows の Sideloadly で行う |

## 2. 設計

### 処理の流れ

```
マイク (AVAudioEngine の入力タップ)
  → AudioProcessor: 2048 サンプル (48kHz で約 43ms) ごとのフレームに分割
  → SpectralAnalyzer: 音量 (dBFS) と、40–600Hz 帯域のエネルギー比を FFT で算出
  → SnoreDetector: いびき判定 → 一定時間内に規定回数ならアラーム
  → SnoreMonitor: VibrationAlarm で振動、ログと画面の更新
```

### いびき判定 (`SnoreDetector`)

1. 環境音の大きさ (ノイズフロア) を常に追従する。静かになる方向には速く、うるさくなる方向にはゆっくり追う
2. ノイズフロア + 感度 (8/12/18 dB) を超えるフレームを「音あり」とし、0.25 秒以内の途切れはつないで 1 つの音にまとめる
3. 長さ 0.3〜3.5 秒で、低音のエネルギー比の平均が 0.55 以上ならいびきとする
4. 前のいびきから 1.5 秒未満のものは同じいびきとみなす
5. 判定時間内に規定回数あればアラームを出し、履歴を消す
6. 3.5 秒を超えて続く音 (エアコン・扇風機など) はノイズフロアに取り込み、いびきとしない

各しきい値は一般的な値から決めた初期値で、**実際のいびきではまだ試していない**。

### 画面ロック中の動作と誤検知対策 (`SnoreMonitor`)

- Info.plist の `UIBackgroundModes = audio` と、マイク入力を動かし続けることでバックグラウンドでも動作する
- オーディオセッションは `.playAndRecord` / `.measurement` (自動ゲイン調整を切る)
- iOS は録音中に振動を止めるため、`setAllowHapticsAndSystemSoundsDuringRecording(true)` で許可している
- 振動は `kSystemSoundID_Vibrate` を 0.7 秒間隔で繰り返す (バックグラウンドでも動く)
- 振動音をいびきと誤検知しないよう、振動中とその後 2 秒は検知を止める
- アプリが前面にないとき (`applicationState != .active`) にアラームが鳴ったら、`AlarmNotifier` でローカル通知を出す。通知音は鳴らさず (振動は設定どおり `VibrationAlarm` が行う)、「振動を止める」アクションで `dismissAlarm()` を呼ぶ
- バックグラウンドでマイクの再開に失敗したら通知で知らせる (監視が止まったことに気付けるように)
- 通知の許可は監視・デモの開始時に求める。拒否されても監視と振動は動く (ログに記録)
- デモはマイクを使わないので、ロック中は `beginBackgroundTask` の猶予 (30 秒程度) の間だけ動く
- 画面が見えない間 (`didEnterBackground` 〜 `willEnterForeground`) は、入力レベル表示のためのメインスレッド更新 (約 10 回/秒) を止め、検出結果だけを通知する (電池・発熱対策)

### いびきの録音

- `SnoreRecorder` がタップのバッファを `AVAudioConverter` で 16kHz モノラルに変換し、`SampleRingBuffer` (6 秒・固定長) に入れ続ける。常時のファイル書き込みはしない
- いびきイベントが来たら、検出と同じ時刻の基準 (どちらも `startEngine` で同時に作る) で前 0.3 秒・後 0.2 秒の余白付きで切り出し、`RecordingStore` が utility キューで AAC 16kHz 24kbps の ADTS (.aac) に保存する
  - `AVAudioFile` は `AVEncoderBitRateKey` を反映しないことがあるため、`ExtAudioFile` の内部コンバーターに `kAudioConverterEncodeBitRate` を直接設定している (エンコーダーが受け付ける値のうち 24kbps に最も近いものを選び、`ConverterConfig` の反映後に読み直して確認)。失敗したら `AVAudioFile` の既定ビットレートで保存
  - 入れ物を m4a にしないのは、m4a は 1 ファイルごとに約 24KB の固定領域が付くため (CI の計測で 2 秒の音声データ 2.2KB に対しファイル 26.8KB。ADTS なら 2.5KB)
- ファイル名 `snore-<UNIX ミリ秒>-<長さミリ秒>-<最大音量 -dB×10>.aac` に日時・長さ・最大音量を入れ、一覧・グラフ表示でファイルを開かない (最大音量のない以前の名前も読める)
- 保存先は Application Support/Recordings (iCloud バックアップ対象外)。起動時と監視開始時に 1 週間より古いものを削除。1 回の監視で最大 1500 件
- 監視中は再生できない (再生音の誤検知防止)。再生は `SnorePlayer` (セッションを `.playback` にし、終わったら非アクティブに戻す)
- **「再生しても何も聞こえない」という報告 (2026-10-22) への対応**: 録音は `.measurement` モード (自動ゲインなし) の生の音量なので、枕元のいびきでもピーク -30dBFS 前後と小さい。再生時にファイル全体を読み込み、ピークが 0.9 になるよう音量を上げて (上限 +30dB) `AVAudioEngine` で鳴らす。また、当時の自動開始の待機中はマイク用セッション (`.playAndRecord` / `.measurement`) を共有して再生していたため音が小さかった (待機の仕組みはその後廃止)
- 再生時の波形表示 (`Waveform`, `WaveformView`): 再生用に読み込んだ録音を、音量を上げる**前**に 120 区間に分け、区間ごとの最大振幅を dB にして -60〜0 dB を高さ 0〜1 に割り当てる (録音どうしで大小を比べられるように、再生時の音量補正の影響を受けない)。上下対称の棒で描き、再生位置は `AVAudioPlayerNode` の再生時刻から求める。画面の更新 (30 回/秒) は再生中だけ。再生後も次の録音を再生するまで表示する
- `RecordingTests.testSnoreRecordingContainsAudibleSoundEndToEnd` で、48kHz の入力 → 検出 → 切り出し → AAC 保存 → 再生用の読み込みまで通し、いびきの音が正しい位置に入っていることを確認している

### 寝る時刻のお知らせ・自動終了 (`MonitoringSchedule`, `SnoreMonitor`, `AlarmNotifier`)

- 時刻は 0 時からの分で UserDefaults に保存 (キー名は以前の「自動開始・終了」のまま: 開始 = お知らせ、終了 = 自動終了)。お知らせ > 終了なら日をまたぐ。同じ時刻は無効
- お知らせは iOS のローカル通知 (`UNCalendarNotificationTrigger`) を、毎日お知らせの時刻から 15 分おきに 4 回 × 7 日分 (28 件) 予約する (`MonitoringSchedule.reminderDates`、`AlarmNotifier.scheduleReminders`)。iOS が持つ予約なのでアプリを終了していても届く。通知音あり
- 通知の「監視を開始」(`.foreground` でアプリを開く) か、通知本体のタップで `SnoreMonitor.startFromReminder()`。**マイクは前面でしか使い始められない**ため、アプリを開いてから開始する
- 監視を始めたら予約し直し、終了時刻までに来る分 (その夜の残り) を出さない。監視の終了時・アプリが前面に来たとき・設定画面を閉じたときにも予約し直す (`applySchedule()`)
- 監視中は終了時刻まで 1 分ごとに起きて時刻を確かめ、終了時刻に止める
- **以前の方式 (2026-10-22〜23 の版) を廃止した経緯**: 開始時刻にバックグラウンドで監視を始めるため、待機中も `AVAudioEngine` を何もしないタップで動かし続けていた。実機で試したところ、マイクを占有してイヤホンマイクが使えない・画面上部のオレンジのマイク表示が終日点いたままになる、という理由で不評だった。充電器の接続をきっかけにする案 (ショートカットのオートメーション) は「充電したいだけのとき」と区別できないため見送り
- アプリを開いているときもお知らせはバナーで出す (`willPresent`)。いびきの通知は前面では出さない

### Apple Watch で知らせる (`WatchAlert`, `SnoreMonitor.alertWithWatch`)

- 隣で眠る人を起こさずに、本人の手首だけを振動させるのがねらい。毎晩確実に振動が届くことを重視し、届かなかったときは iPhone で知らせる。寝る前に接続と集中モードを確認し、朝に送った回数を見せる
- 構成は「iPhone で検知 → iPhone のローカル通知を Watch に転送させて振動」。Watch 用アプリは作らない
  - iPhone から Watch のアプリを起こす手段がない (WatchConnectivity の `sendMessage` は Watch のアプリが前面・高優先度で動いていないと届かず、起こしもしない)
  - Watch の `WKExtendedRuntimeSession` に一晩続く睡眠向けの種類がない (smart alarm は 30 分まで)
  - Watch アプリを埋め込むと、無料 Apple ID + Sideloadly での署名・インストールの難度も上がる
- 転送の条件: iPhone の画面がロック中、Watch を着けてロック解除中。iPhone の通知設定でこのアプリのサウンドがオンでないと Watch が振動しない (報告ベース)。そのため通知は `sound = .default`。Watch に転送されているあいだ iPhone は鳴らないが、Watch を外していると iPhone で鳴る
- 通知 1 回は短い 1 振動なので、振動の長さのあいだ繰り返し送る (`AlarmNotifier.notifyWatch`)。最初の 3 回は 1 秒おき、そのあとは 2 秒おき (実機で 4.5 秒おきでは起きられず、2 秒以下が必要だった。間隔を詰めると読んでいる最中に次の通知が上に重なるが、重なった通知のタップでも止まる)。通知には「振動を止める」ボタン (Watch からも押せる)
- 「振動を止める」などで自分で止めたときは、次のアラームで iPhone の振動 (Watch で起きなかったとき用) を行わない
- 以前は次の通知を送るたびに前の通知を消していたが、Watch でボタンを押すまでに 3 秒以上かかると、押した通知が消えていて止まらなかった (実機で「何回かに一度しか止まらない」)。アラームの間は消さず、終わったら `clearWatchAlerts` でまとめて消す。タップと払いのけ (`customDismissAction`) でも止める
- Watch を消音モードにしないと Watch から通知音が鳴る (実機で確認)。準備の手順で消音モードを案内している
- サウンドなしの通知 (`sound = nil`) は Watch に転送されず、iPhone のロック画面にだけ出る (実機で確認)。通知にはサウンドが必要
- 消音モードの Watch でも、テストの通知・実際のいびきとも振動することを実機で確認 (一度振動しなかった報告があったが、再テストでは振動した。Watch の「触覚による通知」がオンであることが前提)
- 届いたかは確かめられないので: (1) 届かないと分かっているとき (画面表示中・未ペアリング・通知未許可) は iPhone で振動 (2) Watch で知らせてから 5 分以内に再びアラームになったら iPhone も振動 (`watchFallback`、既定オン) (3) Watch への通知回数と代わりの iPhone 振動の回数を今回の記録に表示 (4) メイン画面の「Watch に届くかテスト」(5 秒後に通知)
- 他のアプリを使用中 (アプリはバックグラウンドだが iPhone の画面は点いている) も Watch に転送されないので、iPhone で振動し「振動を止める」付きの通知を出す (2026-10-31 追加、実機未確認)。ロック中との見分けは `isProtectedDataAvailable` (パスコードありの端末で、ロックの約 10 秒後に false になる)。パスコードがない端末は見分けられないためロック中とみなす (`isUsingOtherApp`)
- ペアリングの確認は `WCSession.isPaired` (Watch アプリがなくても分かる)。通知の許可とサウンドは `notificationSettings()`。アプリが前面に来たとき・端末を切り替えたとき・監視の開始時に調べ直す
- 集中モードを抜ける `timeSensitive` は entitlement が必要なため使っていない。集中モードの許可 App に加えてもらう案内にしている
- **実機未確認**: 転送で振動するか、3 秒おきの通知が毎回振動するか、集中モード中の挙動、Watch のモデル・watchOS による差

### 中断からの復帰

- 電話などの中断、入力の変更 (イヤホンの抜き差し)、オーディオのリセットのあとは自動でマイクを再開する
- 中断の終了の知らせが来ない場合に備え、監視中は 5 秒おきにマイク入力が来ているかを確かめ、10 秒途切れていたら再開を試み続ける (`checkInput`)。画面に戻ったとき、ロック中・他のアプリを使用中だった間のいびきの回数と入力の途切れをログに出す (「画面をロック中・ほかのアプリを使用中だった◯分間: …」)
- 監視中は 5 分おきに `MonitoringSessionStore.touch` で「動いていた時刻」を残し、アプリが終了しても一晩の記録で監視時間を出せるようにする

### 日本語の改行 (`PhraseText`)

- 「はじめる」と同じ方式。文字列に `\n` を入れて改行を決め打ちせず、文や説明、ログ、通知の本文は `PhraseText(...)` / `Phrases.wrapped` で出す。BudouX (`griffin-stewie/BudouX.swift` 0.10.0) で文節に分け、文節の中の文字を Word Joiner でつなぎ、文節の間にだけゼロ幅スペースを入れるので、語の途中で折り返さない。段落の区切りの `\n` はそのまま残す
- 短いボタンやラベルは 1 行なのでそのまま

### Watch に届くかテスト

- OK を押すと、バックグラウンドの時間をもらってアプリから 5 秒後に通知を出す (時刻を指定した通知の予約は遅れることがあるため)。通知を出してから Watch に届くまでにも数秒かかり、実機では OK から 8〜10 秒。画面の説明は「すぐにロック」「10 秒ほどで振動」にしている
### 診断ログ (`DiagnosticLog`、開発用)

- 「画面ロック中に検知しない」の調査のために追加。コンパイル条件 `DIAGNOSTICS` のときだけ Application Support/Diagnostics/diagnostics.log に書く (3MB で 1 世代ローテート)。設定画面の「診断 (開発用)」から書き出して共有する
- **リリース前に `project.yml` の `SWIFT_ACTIVE_COMPILATION_CONDITIONS` の行を消す**
- 設定は監視開始時に読み込む (監視中に変えた設定は次回の開始から反映。お知らせ・自動終了の時刻だけは設定画面を閉じるとすぐ反映)

## 3. コードの場所

リポジトリ: `Katogara/SnoreAlarm` (公開)、`main` ブランチ。2026-10-25 に、開発の速さを優先して非公開リポジトリから移した (公開リポジトリは macOS の CI も無料)。移す前の履歴は非公開リポジトリに残してあり、こちらには持ち込んでいない。

| パス | 内容 |
| --- | --- |
| `project.yml` | XcodeGen のプロジェクト定義 (`xcodegen generate` で `.xcodeproj` を生成。`.xcodeproj` はコミットしていない) |
| `SnoreAlarm/Info.plist` | マイク利用の説明文、バックグラウンドオーディオ、縦画面固定 |
| `SnoreAlarm/SnoreAlarmApp.swift` | アプリのエントリーポイント |
| `SnoreAlarm/SnoreMonitor.swift` | 全体の制御 (権限、オーディオセッション、中断からの復帰、アラーム、ログ) |
| `SnoreAlarm/AlarmSettings.swift` | 設定値と UserDefaults のキー、検知設定への変換 |
| `SnoreAlarm/MonitoringSchedule.swift` | 寝る時刻のお知らせを出す時刻と自動終了の時刻の計算 |
| `SnoreAlarm/RecordingStore.swift` | 録音の保存・一覧・自動削除 |
| `SnoreAlarm/SnorePlayer.swift` | 録音の再生 |
| `SnoreAlarm/Audio/SnoreRecorder.swift`, `SampleRingBuffer.swift` | 直近 6 秒の音の保持といびき区間の切り出し |
| `SnoreAlarm/Views/RecordingsView.swift` | 録音一覧 (直近 1 週間) と再生ボタン |
| `SnoreAlarm/Waveform.swift`, `SnoreAlarm/Views/WaveformView.swift` | 再生時の波形 (時間 × 録音したままの音量) |
| `SnoreAlarm/WatchAlert.swift` | 知らせる端末 (`AlertDevice`: iPhone / Watch / 両方)、Watch への通知の間隔と iPhone への切り替えの判定、Watch のペアリング確認 (`WatchLink`) |
| `SnoreAlarm/Views/OnboardingView.swift` | 初回起動時の案内 (知らせる端末の選択と Watch の準備) |
| `SnoreAlarm/AlarmEventStore.swift` | 振動で知らせた記録 (時刻・端末・自分で止めたか。UserDefaults、約 8 日分)。一晩の記録のグラフとまとめに出す |
| `SnoreAlarm/MonitoringSessionStore.swift` | 監視の開始・終了時刻の記録 (UserDefaults、約 8 日分) |
| `SnoreAlarm/NightRecord.swift`, `SnoreAlarm/Views/NightView.swift` | 一晩の記録 (1日の区切りでまとめ、Swift Charts で 時刻 × 録音の最大音量 を表示) |
| `SnoreAlarm/DiagnosticLog.swift` | 開発用の診断ログと設定画面の書き出し (`DIAGNOSTICS` のときだけ動く。リリース前に無効にする) |
| `SnoreAlarm/AlarmNotifier.swift` | バックグラウンドでの振動・マイク停止のローカル通知と、寝る時刻のお知らせ |
| `SnoreAlarm/Audio/AudioProcessor.swift` | マイク入力をフレームに分割して解析・判定に渡す (オーディオスレッドで動く) |
| `SnoreAlarm/Audio/SpectralAnalyzer.swift` | FFT (Accelerate) で音量と低音のエネルギー比を算出 |
| `SnoreAlarm/Audio/SnoreDetector.swift` | いびき判定とアラーム条件 (UI やオーディオに依存しない純粋なロジック) |
| `SnoreAlarm/Audio/VibrationAlarm.swift` | 振動の繰り返し |
| `SnoreAlarm/Audio/DemoSignal.swift` | いびき検知デモ用の疑似フレーム列 (静か 2 秒 + 「いびき 1 秒・静か 1.5 秒」× 設定回数) |
| `SnoreAlarm/Assets.xcassets/AppIcon.appiconset` | アプリアイコン (1024px 1 枚。枕で眠る人 + Zzz + 波形を表示したスマホ + 振動の波線。角は背景色で埋めた正方形) |
| `SnoreAlarm/Views/` | 画面 (`ContentView` メイン、`SettingsView` 設定、`LevelMeter` 入力レベル表示) |
| `SnoreAlarmTests/SnoreDetectorTests.swift` | 判定ロジック 8 件、周波数解析 3 件のユニットテスト |
| `.github/workflows/ios.yml` | macOS ランナーでテスト → 未署名 IPA をビルドし Artifact として保存 (push のたびに実行) |
| `README.md` | ビルド方法、Windows からのインストール手順、使い方、注意事項 |

## 4. 進み具合

### 完了

- [x] アプリ本体の実装 (Swift / SwiftUI)
- [x] ユニットテスト (11 件)
- [x] GitHub Actions でのビルドとテスト (macOS ランナー、push のたびに実行)
- [x] 未署名 IPA の作成 (Artifact `SnoreAlarm-unsigned-ipa`、保存期間 30 日)
- [x] README に Windows + Sideloadly でのインストール手順を記載
- [x] アプリアイコンを追加 (アセットカタログ。XcodeGen の既定で `AppIcon` が使われる)
- [x] いびき検知デモボタン (監視していないときのみ表示。`DemoSignal` を実際の `SnoreDetector` に流し、設定どおりの条件で検知 → 振動まで再現。`DemoSignalTests` で全感度 × 回数 2〜10 回を確認)
- [x] バックグラウンドでいびきを検知したときの通知 (「振動を止める」ボタン付き) と設定どおりの振動
- [x] いびきの録音 (いびき区間のみ、AAC 16kHz)、ログ・一覧からの再生、1 週間での自動削除 (`RecordingTests` で切り出し・保存サイズ・期限切れ削除を確認)
- [x] 寝る時刻のお知らせ (通知から 1 タップで開始) と監視の自動終了 (`MonitoringScheduleTests` で時刻の計算を確認。通知からの開始は実機未確認)。以前の「待機中もマイクを動かして自動開始」は廃止
- [x] Apple Watch で知らせる (初回の案内で iPhone / Watch / 両方を選択、メイン画面の 3 択で切り替え。`WatchAlertTests` で通知の間隔と切り替えの判定を確認。Watch での振動は実機未確認)
- [x] 両方で知らせる (2026-10-25 追加。Watch への通知と iPhone の振動を同時に始める。Watch・iPhone の通知や画面のどれかで止めると、両方の振動が止まり、Watch 向けの通知も消える。実機未確認)
- [x] 一晩の記録のグラフ (`NightRecordTests` で区切り・複数回の監視・終了を記録できなかった監視のまとめ方を確認。録音の最大音量はファイル名に入れ、以前の録音は表示時に読み込んで測る。画面は実機未確認)

### 作業中: Windows PC から iPhone へのインストール

Windows PC 側の準備 (iTunes・iCloud の公式インストーラー版、Sideloadly) は完了。あとは Sideloadly に IPA をドラッグして Apple ID を入れる (ユーザー本人の操作)。

- IPA (Artifact) のダウンロードには GitHub へのログインが必要。ログインしたブラウザで Actions の実行ページからダウンロードする

### 未着手・今後の課題

- [ ] iPhone へのインストール (Sideloadly への Apple ID 入力、iPhone での「信頼」・デベロッパモードはユーザー本人の操作)
- [ ] 実機での動作確認: 画面ロック中の検知継続、振動、マイク許可ダイアログ
- [ ] 実際のいびきで判定のしきい値を調整 (誤検知・見逃しの確認)
- [ ] リリース前に診断ログを無効にする (`project.yml` の `DIAGNOSTICS` の行を消す)

## 5. 注意点・既知の制約

- **無料 Apple ID だと、インストールしたアプリは 7 日で起動できなくなる**。Sideloadly で入れ直すか自動更新機能を使う。年額の Apple Developer Program に登録すれば 1 年有効になり、TestFlight 配布もできる
- Bundle ID は `com.example.SnoreAlarm`。Sideloadly でエラーになる場合は Advanced options で変更する
- 一晩中マイクを使うため電池を消費する。充電しながらの使用を想定
- アプリを上にスワイプして終了すると監視も止まる (寝る時刻のお知らせは iOS が予約を持つので届く)
- 通知から監視を始めるにはアプリが開く (マイクは前面でしか使い始められないため)
- 「設定 > アクセシビリティ > タッチ > バイブレーション」がオフだと振動しない
- 医療機器ではない
- Artifact は 30 日で消える。そのあとは Actions の **Run workflow** で作り直す
