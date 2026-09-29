
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d015e111de44f2eb11b2492d47760b53491bdb1917424f1b8b44e298ab7039c7"
// Source-SHA256: "4e914ede8bfcd06a16085dedc87cb80e692e46122a7c3ceef340e65fffddb3b3"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

struct WelcomePage: View {
    @Binding var currentPage: Int
    private let onEnter: (() -> Void)?

    @State private var showContent = false

    init(currentPage: Binding<Int>, onEnter: (() -> Void)? = nil) {
        self._currentPage = currentPage
        self.onEnter = onEnter
    }

    init(onEnter: @escaping () -> Void) {
        self._currentPage = .constant(0)
        self.onEnter = onEnter
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.07)
                .ignoresSafeArea()

            SolarSystemPortalBackground()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.70)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // ✅ 顶部 bar：左上角品牌签名 + 右上角"跳过"
                HStack {
                    Text("ChatAGI-阿杜")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.85), radius: 8)
                        .opacity(showContent ? 1 : 0)
                        .offset(x: showContent ? 0 : -16)
                        .animation(.easeOut(duration: 0.7), value: showContent)

                    Spacer()

                    if onEnter != nil {
                        Button("跳过") {
                            enterApp()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.8))
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                Spacer()  // ✅ 中央完全留给太阳系

                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text("你的智能体分身")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.85), radius: 10)

                        Text("记忆迁移 · 持续陪伴 · AGI 延续")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.88))
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.75), radius: 8)

                        Text("让你的记忆与思考方式持续存在，\n并在未来迁移到更强的智能载体中。")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .shadow(color: .black.opacity(0.75), radius: 8)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 16)
                    .animation(.easeOut(duration: 0.8).delay(0.12), value: showContent)

                    Button {
                        enterApp()
                    } label: {
                        HStack(spacing: 10) {
                            Text("进入 ChatAGI")
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(Color.black.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(Color.white)
                        )
                    }
                    .buttonStyle(.plain)
                    .pressHaptics(.heavy)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 38)
            }
        }
        .onAppear {
            showContent = true
        }
    }

    private func enterApp() {
        WelcomeHaptics.success()
        if let onEnter {
            onEnter()
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                currentPage = 3
            }
        }
    }
}

// MARK: - Solar System Background (Web Parity v2 — TimelineView 精确版)
// 严格对应网页 your-service.example.com 的 CSS keyframes，
// 用 TimelineView 驱动每帧时间，避免 SwiftUI animation modifier 的相位塌缩问题。

private struct SolarSystemPortalBackground: View {

    // 8 颗行星轨道直径（相对系统直径的比例 = 网页 .orbit.X 的 width 百分比）
    private let orbitDiameter: [CGFloat] = [0.14, 0.22, 0.32, 0.42, 0.58, 0.72, 0.86, 0.98]

    // 公转周期（秒）—— 严格对应网页 orbitMercury 6s, orbitVenus 10s ...
    private let orbitPeriod: [Double] = [6, 10, 14, 20, 32, 44, 58, 72]

    // 起始相位（度）—— 对应网页 keyframes 起始角错位
    private let orbitPhase: [Double] = [0, 45, 90, 135, 180, 225, 270, 315]

    // 行星直径（pt）—— 网页用 8/12/13/10/26/22/16/16，iOS 适当缩放
    private let planetSize: [CGFloat] = [9, 14, 16, 12, 28, 24, 18, 18]

    private let planetSkins: [PlanetSkin] = [
        .mercury, .venus, .earth, .mars, .jupiter, .saturn, .uranus, .neptune
    ]

    var body: some View {
        GeometryReader { geo in
            // 系统总尺寸：取较小边的 95%
            let side = min(geo.size.width, geo.size.height) * 0.95
            // 中心：屏幕中央
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            // 用 TimelineView 60fps 驱动所有动画
            TimelineView(.animation) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    StarFieldView()

                    // ==== HUD 外环（最远） ====
                    HaloRingView(
                        diameter: side * 1.04,
                        color: Color(red: 0.83, green: 0.69, blue: 0.42),
                        dashed: false,
                        rotationDeg: -(now / 90.0) * 360,    // 90s 反向
                        withMarkers: false
                    )
                    .position(center)

                    HaloRingView(
                        diameter: side * 1.08,
                        color: Color(red: 0.31, green: 0.90, blue: 0.76),
                        dashed: true,
                        rotationDeg: (now / 60.0) * 360,     // 60s 正向
                        withMarkers: true
                    )
                    .position(center)

                    // ==== 8 条轨道环 ====
                    ForEach(0..<8, id: \.self) { idx in
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                            .frame(width: side * orbitDiameter[idx],
                                   height: side * orbitDiameter[idx])
                            .position(center)
                    }

                    // ==== 数据流光点（沿轨道反向流动）====
                    ForEach(0..<8, id: \.self) { idx in
                        let radius = side * orbitDiameter[idx] / 2
                        let angle = -(now / (orbitPeriod[idx] * 1.3)) * 360 + orbitPhase[idx] * 0.5
                        let pos = orbitPosition(center: center, radius: radius, angleDeg: angle)
                        Circle()
                            .fill(Color(red: 0.31, green: 0.90, blue: 0.76))
                            .frame(width: 4, height: 4)
                            .shadow(color: Color(red: 0.31, green: 0.90, blue: 0.76).opacity(0.9), radius: 4)
                            .shadow(color: Color(red: 0.31, green: 0.90, blue: 0.76).opacity(0.5), radius: 8)
                            .position(pos)
                    }

                    // ==== 太阳（含三段式呼吸 + 日冕扩散）====
                    GlowSun(now: now)
                        .frame(width: side * 0.12, height: side * 0.12)
                        .position(center)

                    // ==== 8 大行星 ====
                    ForEach(0..<8, id: \.self) { idx in
                        let radius = side * orbitDiameter[idx] / 2
                        let angle = (now / orbitPeriod[idx]) * 360 + orbitPhase[idx]
                        let pos = orbitPosition(center: center, radius: radius, angleDeg: angle)
                        let glowPulse = 0.5 + 0.5 * sin(now * 2.0 + Double(idx))   // 3s 呼吸

                        ZStack {
                            // 光晕脉冲
                            Circle()
                                .fill(planetSkins[idx].glowColor.opacity(0.20 + glowPulse * 0.25))
                                .frame(width: planetSize[idx] * (1.5 + CGFloat(glowPulse) * 0.4),
                                       height: planetSize[idx] * (1.5 + CGFloat(glowPulse) * 0.4))
                                .blur(radius: 4)

                            // 行星本体
                            planetSkins[idx].body(size: planetSize[idx])

                            // 土星环（如果是土星）
                            if planetSkins[idx].hasRing {
                                Ellipse()
                                    .stroke(Color(red: 0.86, green: 0.78, blue: 0.63).opacity(0.7), lineWidth: 1.4)
                                    .frame(width: planetSize[idx] * 2.0,
                                           height: planetSize[idx] * 0.55)
                                    .rotationEffect(.degrees(-18))
                                    .shadow(color: Color(red: 0.86, green: 0.78, blue: 0.63).opacity(0.4), radius: 3)
                            }
                        }
                        .shadow(color: planetSkins[idx].glowColor.opacity(0.6), radius: 6)
                        .position(pos)
                    }
                }
            }
        }
    }

    // 计算行星在轨道上某角度的精确位置
    private func orbitPosition(center: CGPoint, radius: CGFloat, angleDeg: Double) -> CGPoint {
        let rad = angleDeg * .pi / 180.0
        return CGPoint(
            x: center.x + radius * CGFloat(cos(rad)),
            y: center.y + radius * CGFloat(sin(rad))
        )
    }
}

// MARK: - HUD Halo Ring
private struct HaloRingView: View {
    let diameter: CGFloat
    let color: Color
    let dashed: Bool
    let rotationDeg: Double
    let withMarkers: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    color.opacity(0.18),
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: dashed ? [6, 8] : []
                    )
                )

            if withMarkers {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(color.opacity(0.85))
                        .frame(width: 6, height: 6)
                        .shadow(color: color.opacity(0.7), radius: 4)
                        .offset(y: -diameter / 2)
                        .rotationEffect(.degrees(Double(i) * 90))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(rotationDeg))
    }
}

// MARK: - Planet Skin
private enum PlanetSkin {
    case mercury, venus, earth, mars, jupiter, saturn, uranus, neptune

    var glowColor: Color {
        switch self {
        case .mercury: return Color(red: 0.79, green: 0.72, blue: 0.60)
        case .venus:   return Color(red: 1.00, green: 0.88, blue: 0.66)
        case .earth:   return Color(red: 0.30, green: 0.69, blue: 1.00)
        case .mars:    return Color(red: 1.00, green: 0.47, blue: 0.33)
        case .jupiter: return Color(red: 0.85, green: 0.71, blue: 0.54)
        case .saturn:  return Color(red: 0.94, green: 0.85, blue: 0.63)
        case .uranus:  return Color(red: 0.36, green: 0.77, blue: 0.85)
        case .neptune: return Color(red: 0.29, green: 0.47, blue: 1.00)
        }
    }

    var hasRing: Bool { self == .saturn }

    @ViewBuilder
    func body(size: CGFloat) -> some View {
        switch self {
        case .mercury:
            Circle().fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.79, green: 0.72, blue: 0.60),
                        Color(red: 0.43, green: 0.37, blue: 0.28),
                        Color(red: 0.23, green: 0.19, blue: 0.14)
                    ],
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 1, endRadius: size
                )
            )
            .frame(width: size, height: size)

        case .venus:
            Circle().fill(
                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.89, blue: 0.66),
                        Color(red: 0.83, green: 0.60, blue: 0.29),
                        Color(red: 0.48, green: 0.29, blue: 0.09)
                    ],
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 1, endRadius: size
                )
            )
            .frame(width: size, height: size)

        case .earth:
            ZStack {
                Circle().fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.13, green: 0.59, blue: 0.95),
                            Color(red: 0.05, green: 0.28, blue: 0.63)
                        ],
                        center: .center, startRadius: 1, endRadius: size
                    )
                )
                Circle()
                    .fill(Color(red: 0.30, green: 0.69, blue: 0.31).opacity(0.55))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .offset(x: -size * 0.15, y: size * 0.10)
                    .blur(radius: 1)
                Circle()
                    .fill(Color(red: 0.18, green: 0.49, blue: 0.20).opacity(0.5))
                    .frame(width: size * 0.4, height: size * 0.4)
                    .offset(x: size * 0.15, y: size * 0.20)
                    .blur(radius: 1)
                Circle()
                    .fill(Color(red: 0.66, green: 0.90, blue: 1.0).opacity(0.4))
                    .frame(width: size * 0.4, height: size * 0.4)
                    .offset(x: size * 0.18, y: -size * 0.18)
                    .blur(radius: 1.5)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

        case .mars:
            Circle().fill(
                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.60, blue: 0.40),
                        Color(red: 0.80, green: 0.27, blue: 0.13),
                        Color(red: 0.35, green: 0.10, blue: 0.04)
                    ],
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 1, endRadius: size
                )
            )
            .frame(width: size, height: size)

        case .jupiter:
            ZStack {
                Circle().fill(Color(red: 0.85, green: 0.71, blue: 0.54))
                VStack(spacing: 0) {
                    Rectangle().fill(Color(red: 0.69, green: 0.53, blue: 0.35)).frame(height: size * 0.18)
                    Rectangle().fill(Color(red: 0.91, green: 0.78, blue: 0.61)).frame(height: size * 0.14)
                    Rectangle().fill(Color(red: 0.79, green: 0.60, blue: 0.37)).frame(height: size * 0.16)
                    Rectangle().fill(Color(red: 0.85, green: 0.71, blue: 0.54)).frame(height: size * 0.20)
                    Rectangle().fill(Color(red: 0.69, green: 0.53, blue: 0.35)).frame(height: size * 0.16)
                    Rectangle().fill(Color(red: 0.91, green: 0.78, blue: 0.61)).frame(height: size * 0.16)
                }
                .frame(width: size, height: size)
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: size * 0.4, height: size * 0.4)
                    .offset(x: -size * 0.18, y: -size * 0.18)
                    .blur(radius: 2)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

        case .saturn:
            ZStack {
                Circle().fill(Color(red: 0.94, green: 0.85, blue: 0.63))
                VStack(spacing: 0) {
                    Rectangle().fill(Color(red: 0.94, green: 0.85, blue: 0.63)).frame(height: size * 0.25)
                    Rectangle().fill(Color(red: 0.79, green: 0.66, blue: 0.41)).frame(height: size * 0.25)
                    Rectangle().fill(Color(red: 0.91, green: 0.78, blue: 0.56)).frame(height: size * 0.25)
                    Rectangle().fill(Color(red: 0.79, green: 0.66, blue: 0.41)).frame(height: size * 0.25)
                }
                .frame(width: size, height: size)
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: size * 0.4, height: size * 0.4)
                    .offset(x: -size * 0.18, y: -size * 0.18)
                    .blur(radius: 2)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

        case .uranus:
            Circle().fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.72, green: 0.94, blue: 1.0),
                        Color(red: 0.36, green: 0.77, blue: 0.85),
                        Color(red: 0.10, green: 0.42, blue: 0.50)
                    ],
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 1, endRadius: size
                )
            )
            .frame(width: size, height: size)

        case .neptune:
            Circle().fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.42, green: 0.66, blue: 1.0),
                        Color(red: 0.16, green: 0.30, blue: 0.78),
                        Color(red: 0.04, green: 0.11, blue: 0.37)
                    ],
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 1, endRadius: size
                )
            )
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Sun (TimelineView 驱动的三段式呼吸)
private struct GlowSun: View {
    let now: TimeInterval

    var body: some View {
        // 5 秒一周期的三段式呼吸：calm → dim → bright → calm
        let phase = (now.truncatingRemainder(dividingBy: 5.0)) / 5.0  // 0..1
        let breathe = sunBreathe(phase: phase)

        // 日冕扩散圈（3 秒一周期）
        let coronaA = (now.truncatingRemainder(dividingBy: 3.0)) / 3.0
        let coronaB = ((now + 1.5).truncatingRemainder(dividingBy: 3.0)) / 3.0

        ZStack {
            // 日冕扩散圈 A
            Circle()
                .stroke(
                    Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.6 * (1 - coronaA)),
                    lineWidth: 2 - coronaA * 1.5
                )
                .scaleEffect(1.0 + coronaA * 1.4)

            // 日冕扩散圈 B
            Circle()
                .stroke(
                    Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.6 * (1 - coronaB)),
                    lineWidth: 2 - coronaB * 1.5
                )
                .scaleEffect(1.0 + coronaB * 1.4)

            // 远场暖光
            Circle()
                .fill(Color(red: 1.0, green: 0.66, blue: 0.20).opacity(breathe.farOpacity))
                .scaleEffect(breathe.farScale)
                .blur(radius: 35)

            // 中场光晕
            Circle()
                .fill(Color(red: 1.0, green: 0.78, blue: 0.30).opacity(breathe.midOpacity))
                .scaleEffect(breathe.midScale)
                .blur(radius: 16)

            // 太阳本体
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white,
                            Color(red: 1.0, green: 0.86, blue: 0.44),
                            Color(red: 1.0, green: 0.58, blue: 0.18),
                            Color(red: 0.77, green: 0.38, blue: 0.06)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.35),
                        startRadius: 1,
                        endRadius: 60
                    )
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                )
                .shadow(
                    color: Color(red: 1.0, green: 0.66, blue: 0.20).opacity(0.6 + breathe.bodyExtra),
                    radius: 16 + breathe.bodyExtra * 12
                )
        }
    }

    // 三段式呼吸：基于 phase 0..1 计算各层光晕参数
    private func sunBreathe(phase: Double) -> (farOpacity: Double, farScale: CGFloat,
                                                 midOpacity: Double, midScale: CGFloat,
                                                 bodyExtra: Double) {
        // 5 秒周期：0% calm → 35% dim → 65% bright → 100% calm
        // 用余弦平滑插值
        let p = phase * 2 * .pi
        let t = (1 - cos(p)) / 2  // 0..1..0
        let dim2bright = sin(p)    // -1..0..1..0..-1

        let farOp = 0.18 + dim2bright * 0.10   // 0.08..0.28
        let farSc = 1.50 + dim2bright * 0.35   // 1.15..1.85
        let midOp = 0.32 + dim2bright * 0.13   // 0.19..0.45
        let midSc = 1.30 + dim2bright * 0.25   // 1.05..1.55
        let extra = dim2bright * 0.15          // -0.15..0.15

        _ = t  // 未使用，留作扩展
        return (farOp, CGFloat(farSc), midOp, CGFloat(midSc), extra)
    }
}

// MARK: - Star Field
private struct StarFieldView: View {
    private let stars: [PortalStar] = (0..<140).map { i in
        let seed = Double(i)
        let x = (sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude
        let y = (sin((seed + 31.7) * 8.173) * 15731.743).truncatingRemainder(dividingBy: 1).magnitude
        let size = 0.8 + (Double(i % 3) * 0.7)
        let opacity = 0.25 + (Double((i * 7) % 10) / 22.0)
        return PortalStar(x: x, y: y, size: size, opacity: opacity)
    }
    @State private var twinkle = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(stars.enumerated()), id: \.offset) { _, star in
                    Circle()
                        .fill(Color.white.opacity(star.opacity * (twinkle ? 1.3 : 0.7)))
                        .frame(width: star.size, height: star.size)
                        .position(x: geo.size.width * star.x, y: geo.size.height * star.y)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                twinkle = true
            }
        }
    }
}

private struct PortalStar {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let opacity: Double

    init(x: Double, y: Double, size: Double, opacity: Double) {
        self.x = CGFloat(abs(x))
        self.y = CGFloat(abs(y))
        self.size = CGFloat(size)
        self.opacity = opacity
    }
}

// MARK: - Haptics + Press
private enum WelcomeHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }

    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }
}

private struct PressHapticModifier: ViewModifier {
    let style: UIImpactFeedbackGenerator.FeedbackStyle

    @State private var fired = false
    @GestureState private var isDown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isDown ? 0.985 : 1.0)
            .opacity(isDown ? 0.985 : 1.0)
            .shadow(color: Color.black.opacity(isDown ? 0.18 : 0.28),
                    radius: isDown ? 10 : 16,
                    x: 0,
                    y: isDown ? 6 : 12)
            .animation(.easeOut(duration: 0.12), value: isDown)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDown) { _, state, _ in state = true }
                    .onChanged { _ in
                        if !fired {
                            fired = true
                            WelcomeHaptics.impact(style)
                        }
                    }
                    .onEnded { _ in fired = false }
            )
    }
}

private extension View {
    func pressHaptics(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .heavy) -> some View {
        modifier(PressHapticModifier(style: style))
    }
}



