import SwiftUI

/// 現在の音量と、いびき判定のしきい値を表示するメーター。
struct LevelMeter: View {
    var levelDB: Float
    var thresholdDB: Float?

    private static let range: ClosedRange<Float> = -80...0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(isAboveThreshold ? Color.orange : Color.green)
                        .frame(width: proxy.size.width * fraction(levelDB))
                        .animation(.linear(duration: 0.1), value: levelDB)
                    if let thresholdDB {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: proxy.size.width * fraction(thresholdDB) - 1)
                    }
                }
            }
            .frame(height: 14)

            HStack {
                Text(String(format: "%.0f dB", levelDB))
                    .monospacedDigit()
                Spacer()
                if let thresholdDB {
                    Text(String(format: "しきい値 %.0f dB", thresholdDB))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var isAboveThreshold: Bool {
        thresholdDB.map { levelDB >= $0 } ?? false
    }

    private func fraction(_ db: Float) -> CGFloat {
        let clamped = min(max(db, Self.range.lowerBound), Self.range.upperBound)
        return CGFloat((clamped - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound))
    }
}
