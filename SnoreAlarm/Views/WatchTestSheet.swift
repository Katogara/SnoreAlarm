import SwiftUI

/// 「Watch に届くかテスト」の説明画面。OK を押すと少し後に通知を出すので、その間に iPhone をロックしてもらう。
struct WatchTestSheet: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WatchTestIllustration()
                        .frame(maxWidth: .infinity)

                    PhraseText("OK を押すと、\(Int(SnoreMonitor.watchTestDelay))秒後に Apple Watch に通知を出します。")
                        .font(.headline)
                    // 通知を出してから Watch に届くまでにも数秒かかる (実機で OK から 8〜10 秒)
                    PhraseText("iPhone の通知が Watch に届くのは、iPhone の画面がロックされているときだけです。OK を押したら、すぐに iPhone のサイドボタンを押して画面をロックしてください。通知を出してから Watch に届くまで、さらに数秒かかることがあります (OK を押してから\(Int(SnoreMonitor.watchTestArrival))秒ほど)。")
                    PhraseText("Watch が振動すれば準備は完了です。Watch から音が鳴ったときは、Watch を消音モードにしてください (コントロールセンターのベルのボタン。消音モードでも振動します)。Watch が振動せず iPhone に通知が出たときは、ロックが間に合わなかったか、Watch の準備がまだです (「設定」>「Apple Watch で使うための準備」)。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await monitor.testWatchAlert() }
                        dismiss()
                    } label: {
                        Text("OK")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle("Watch に届くかテスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
        }
    }
}

/// テストの手順を繰り返し見せるイラスト: OK をタップ → すぐに画面をロック → Watch に通知が届いて振動
private struct WatchTestIllustration: View {
    private enum Step: CaseIterable {
        case showOK, tapOK, lock, notify

        var duration: Double {
            switch self {
            case .showOK: 1.2
            case .tapOK: 1.2
            case .lock: 1.6
            case .notify: 2.4
            }
        }

        var caption: String {
            switch self {
            case .showOK, .tapOK: "① OK をタップ"
            case .lock: "② すぐにサイドボタンで画面をロック"
            case .notify: "③ \(Int(SnoreMonitor.watchTestArrival))秒ほどで Watch が振動"
            }
        }
    }

    @State private var step: Step = .showOK

    private var isLocked: Bool { step == .lock || step == .notify }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 28) {
                phone
                watch
            }
            .frame(height: 190)

            Text(step.caption)
                .font(.subheadline.bold())
                .contentTransition(.opacity)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OK をタップしたらすぐに iPhone の画面をロックすると、\(Int(SnoreMonitor.watchTestArrival))秒ほどで Apple Watch が振動します")
        .task {
            // 画面を閉じるまで手順を繰り返す
            while !Task.isCancelled {
                for next in Step.allCases {
                    withAnimation(.easeInOut(duration: 0.35)) { step = next }
                    try? await Task.sleep(for: .seconds(next.duration))
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private var phone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(isLocked ? Color.black : Color(.systemBackground))
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary, lineWidth: 4)

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            } else {
                Text("OK")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule())
                    .scaleEffect(step == .tapOK ? 0.88 : 1)
                    .transition(.opacity)
            }

            // タップする指
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .offset(x: 14, y: 26)
                .opacity(step == .tapOK ? 1 : 0)
        }
        .frame(width: 92, height: 180)
        .overlay(alignment: .trailing) {
            // サイドボタン。ロックするときに押す
            RoundedRectangle(cornerRadius: 2)
                .fill(step == .lock ? Color.orange : Color.primary)
                .frame(width: step == .lock ? 7 : 5, height: 30)
                .offset(x: step == .lock ? 4 : 5, y: -30)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "arrow.left")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.orange)
                .offset(x: 30, y: -30)
                .opacity(step == .lock ? 1 : 0)
        }
    }

    private var watch: some View {
        VStack(spacing: 0) {
            band
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black)
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary, lineWidth: 4)
                VStack(spacing: 4) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.orange)
                    Text("いびき\nアラーム")
                        .font(.system(size: 9, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 84)
            .overlay {
                // 振動を表す波
                HStack(spacing: 84) {
                    Image(systemName: "wave.3.left")
                    Image(systemName: "wave.3.right")
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.variableColor.iterative, isActive: step == .notify)
            }
            band
        }
        .modifier(Shake(amount: step == .notify ? 1 : 0))
        .opacity(step == .notify ? 1 : 0)
        .scaleEffect(step == .notify ? 1 : 0.7)
    }

    private var band: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.7))
            .frame(width: 50, height: 36)
    }
}

/// 振動しているように左右に小刻みに揺らす
private struct Shake: GeometryEffect {
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 3 * sin(amount * .pi * 8), y: 0))
    }
}
