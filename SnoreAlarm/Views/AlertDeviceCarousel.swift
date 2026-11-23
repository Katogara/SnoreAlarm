import SwiftUI

/// 知らせる端末を、楕円の軌道を回る 3D のカルーセルで選ぶ。
/// 手前に来た端末が選んでいる端末で、大きく色付きで出す。奥の端末は小さく薄くぼかし、軌道に沿って傾けて出す。
/// 左右になぞると回り、指を離すといちばん近い端末で止まる。奥の端末を押すと、その端末が手前に回ってくる
struct AlertDeviceCarousel: View {
    @Binding var selection: AlertDevice
    /// 回転の位置 (端末 1 つ分が 1)。整数 n のとき、n 番目 (端末の数で割った余り) の端末が手前に来る
    @State private var rotation: Double
    /// なぞり始めたときの `rotation`。縦になぞったとき (リストのスクロール) は nil のまま
    @State private var dragStart: Double?

    private static let devices = AlertDevice.allCases
    private static let height: CGFloat = 150
    private static let spring = Animation.spring(response: 0.55, dampingFraction: 0.72)

    init(selection: Binding<AlertDevice>) {
        _selection = selection
        _rotation = State(initialValue: Double(Self.index(of: selection.wrappedValue)))
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let radiusX = proxy.size.width * 0.33
                let radiusY: CGFloat = 16
                let step = max(radiusX * 0.9, 1)
                ZStack {
                    // 軌道
                    Ellipse()
                        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                        .frame(width: radiusX * 2, height: radiusY * 2 + 20)
                        .offset(y: 34)
                    // 手前の端末の足元の光
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: 60))
                        .frame(width: 130, height: 26)
                        .offset(y: radiusY + 42)
                        .blur(radius: 2)

                    ForEach(Array(Self.devices.enumerated()), id: \.element) { index, device in
                        Button {
                            settle(at: nearestRotation(to: index))
                        } label: {
                            OrbitItem(device: device, index: index, count: Self.devices.count,
                                      rotation: rotation, radiusX: radiusX, radiusY: radiusY)
                        }
                        // List の行の中に複数のボタンを置くため、.plain にして行全体が押されないようにする
                        .buttonStyle(.plain)
                        .zIndex(OrbitItem.depth(index: index, count: Self.devices.count, rotation: rotation))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                // リストの縦のスクロールを止めないよう、横になぞったときだけ回す
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if dragStart == nil {
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                dragStart = rotation
                            }
                            if let start = dragStart {
                                rotation = start - value.translation.width / step
                            }
                        }
                        .onEnded { value in
                            guard let start = dragStart else { return }
                            dragStart = nil
                            // はじいたときは勢いの分だけ進める (一度に 2 つまで)
                            let moved = -value.predictedEndTranslation.width / step
                            settle(at: (start + min(max(moved, -2), 2)).rounded())
                        }
                )
            }
            .frame(height: Self.height)

            Text(selection.label)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: selection)

            HStack(spacing: 6) {
                ForEach(Self.devices) { device in
                    Capsule()
                        .fill(device == selection ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: device == selection ? 18 : 6, height: 6)
                }
            }
            .animation(Self.spring, value: selection)
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection) {
            // ほかの画面で端末を変えたときも、選んだ端末を手前に回す
            if dragStart == nil && device(at: rotation.rounded()) != selection {
                settle(at: nearestRotation(to: Self.index(of: selection)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("知らせる端末")
        .accessibilityValue(selection.label)
        .accessibilityHint("上下にスワイプして切り替えます")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: settle(at: rotation.rounded() + 1)
            case .decrement: settle(at: rotation.rounded() - 1)
            @unknown default: break
            }
        }
    }

    private static func index(of device: AlertDevice) -> Int {
        devices.firstIndex(of: device) ?? 0
    }

    private func device(at rotation: Double) -> AlertDevice {
        let count = Self.devices.count
        let index = (Int(rotation) % count + count) % count
        return Self.devices[index]
    }

    /// `index` 番目の端末を手前に出す回転の位置のうち、いまの位置からいちばん近いもの (回る量がいちばん少ない向き)
    private func nearestRotation(to index: Int) -> Double {
        (rotation + OrbitItem.wrapped(Double(index) - rotation, count: Self.devices.count)).rounded()
    }

    /// 回転の位置を `target` まで回して止め、手前に来た端末を選ぶ
    private func settle(at target: Double) {
        withAnimation(Self.spring) {
            rotation = target
        }
        let device = device(at: target)
        if device != selection {
            selection = device
        }
    }
}

/// 軌道の上の端末 1 つ。回転の位置 (`rotation`) をアニメーションさせ、楕円に沿って動かす
/// (位置だけをアニメーションさせると、手前と奥のあいだを直線で動いてしまうため)
private struct OrbitItem: View, Animatable {
    let device: AlertDevice
    let index: Int
    let count: Int
    var rotation: Double
    let radiusX: CGFloat
    let radiusY: CGFloat

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    /// -count/2 〜 count/2 に収める
    static func wrapped(_ value: Double, count: Int) -> Double {
        let n = Double(count)
        return value - n * (value / n).rounded()
    }

    static func angle(index: Int, count: Int, rotation: Double) -> Double {
        wrapped(Double(index) - rotation, count: count) * 2 * .pi / Double(count)
    }

    /// 手前が 1、奥が -1
    static func depth(index: Int, count: Int, rotation: Double) -> Double {
        cos(angle(index: index, count: count, rotation: rotation))
    }

    var body: some View {
        let angle = Self.angle(index: index, count: count, rotation: rotation)
        let near = (cos(angle) + 1) / 2 // 手前が 1、奥が 0
        DeviceOrb(device: device, near: near)
            .scaleEffect(0.5 + 0.5 * near)
            .opacity(0.35 + 0.65 * near)
            .blur(radius: (1 - near) * 1.5)
            .rotation3DEffect(.radians(-sin(angle) * 0.7), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .offset(x: sin(angle) * radiusX, y: cos(angle) * radiusY)
    }
}

/// 端末のアイコンを入れたガラスの玉。手前に来るほど色と影を濃くする
private struct DeviceOrb: View {
    let device: AlertDevice
    let near: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.28 * near), Color.accentColor.opacity(0.04 * near)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.7), Color.white.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
            AlertDeviceIcon(device: device)
                .foregroundStyle(near > 0.5
                                 ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                                                startPoint: .top, endPoint: .bottom))
                                 : AnyShapeStyle(Color.secondary))
        }
        .frame(width: 92, height: 92)
        .shadow(color: Color.accentColor.opacity(0.35 * near * near), radius: 14 * near, y: 8 * near)
    }
}

/// 知らせる端末のアイコン。両方は iPhone と Watch を並べる
private struct AlertDeviceIcon: View {
    let device: AlertDevice

    var body: some View {
        switch device {
        case .iPhone:
            Image(systemName: "iphone")
                .font(.system(size: 40))
        case .watch:
            Image(systemName: "applewatch")
                .font(.system(size: 40))
        case .both:
            HStack(alignment: .bottom, spacing: 1) {
                Image(systemName: "iphone")
                    .font(.system(size: 34))
                Image(systemName: "applewatch")
                    .font(.system(size: 24))
            }
        }
    }
}
