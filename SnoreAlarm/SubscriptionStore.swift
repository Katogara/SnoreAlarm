import Observation
import StoreKit
import SwiftUI

/// サブスクリプション (App Store の自動更新サブスクリプション)。月額と年額の 2 つを、App Store Connect の同じグループに置く。
/// 同じグループなので、どちらか 1 つだけに加入でき、乗り換えは Apple が日割りなどを扱う。
/// 無料の体験期間は App Store Connect の「お試しオファー」で設定し、Apple がグループごとに 1 つの Apple ID につき 1 回だけ適用する。
/// 登録していないときは、いびきの監視 (おやすみコールを含む) だけを止め、記録・録音・グラフ・デモは使えるままにする。
@MainActor
@Observable
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    /// App Store Connect で作るサブスクリプションの製品 ID (月額・年額)。登録画面にはこの順に並ぶ
    static let productIDs = ["snorealarm.monthly", "snorealarm.yearly"]

    /// 登録していないと監視できないようにするか。
    /// 署名なしで入れる開発中のビルドでは App Store から製品を読めず登録できないため、止めない。
    /// App Store に出すときに、project.yml の SWIFT_ACTIVE_COMPILATION_CONDITIONS に SUBSCRIPTION_REQUIRED を足す
    #if SUBSCRIPTION_REQUIRED
    static let isRequired = true
    #else
    static let isRequired = false
    #endif

    /// 利用規約 (Apple の標準の使用許諾契約)
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// プライバシーポリシー (リポジトリの PRIVACY.md)。App Store Connect にも同じ URL を入れる
    static let privacyURL = URL(string: "https://github.com/Katogara/SnoreAlarm/blob/main/PRIVACY.md")!

    /// 登録中 (無料の体験期間を含む)
    private(set) var isSubscribed: Bool
    /// 登録の画面をメイン画面に出す (登録していないのに監視を始めようとしたとき)
    var isPaywallPresented = false

    /// いびきの監視を使える
    var canMonitor: Bool { !Self.isRequired || isSubscribed }

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init() {
        isSubscribed = UserDefaults.standard.bool(forKey: AlarmSettings.Key.subscriptionActive)
        // ほかの端末での登録・更新・解約、返金などを受け取る
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
    }

    /// 登録中かを確かめ直す。端末内の記録を読むだけなので、通信を待たない
    func refresh() async {
        var active = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            active = true
        }
        guard active != isSubscribed else { return }
        isSubscribed = active
        UserDefaults.standard.set(active, forKey: AlarmSettings.Key.subscriptionActive)
        DiagnosticLog.write("subscription: active=\(active)")
        // おやすみコールは、登録しているときだけ予約する
        SnoreMonitor.shared.applySchedule()
    }
}

/// サブスクリプションの登録画面。価格と無料の体験期間は App Store の設定から表示される
struct PaywallView: View {
    @Environment(SubscriptionStore.self) private var subscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: SubscriptionStore.productIDs) {
            VStack(spacing: 16) {
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
                    .padding(.top, 24)
                Text("いびきの監視を使うには")
                    .font(.title2.bold())
                PhraseText("いびきの監視とおやすみコールは、サブスクリプションに登録すると使えます。登録していなくても、これまでの記録と録音は見られます。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        }
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .cancellation)
        .subscriptionStorePolicyDestination(url: SubscriptionStore.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: SubscriptionStore.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result, case .verified(let transaction) = verification {
                await transaction.finish()
            }
            await subscription.refresh()
        }
        .task {
            // 「購入を復元」の結果は知らせが来ないため、開いているあいだは確かめ続ける
            while !Task.isCancelled {
                await subscription.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: subscription.isSubscribed) { _, subscribed in
            if subscribed { dismiss() }
        }
    }
}

/// 設定画面のサブスクリプションの欄。画面は Form に付けて出す
/// (List の Section に付けると行ごとに付いて、開いた直後に閉じてしまうため)
struct SubscriptionSection: View {
    @Environment(SubscriptionStore.self) private var subscription
    @Binding var showingPaywall: Bool
    @Binding var showingManage: Bool

    var body: some View {
        Section {
            LabeledContent("状態", value: subscription.isSubscribed ? String(localized: "登録中") : String(localized: "未登録"))
            if subscription.isSubscribed {
                Button("登録内容の確認・解約") { showingManage = true }
            } else {
                Button("登録する") { showingPaywall = true }
            }
        } header: {
            Text("サブスクリプション")
        } footer: {
            PhraseText("登録していなくても、これまでの記録と録音は見られます。解約は、更新日の24時間前までに行ってください。")
        }
    }
}
