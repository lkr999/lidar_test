import UIKit

/// LiDAR 스캔 중 AR 뷰 위에 표시되는 오버레이
///
/// - 스캔 가이드 직사각형 + 스윕 애니메이션
/// - 5개 품질 지표 실시간 바 차트
/// - 진행률 아크
/// - 자동 종료 준비 배너
class ScanOverlayView: UIView {

    // MARK: - State

    private var scanProgress: Double = 0
    private var quality = MeasurementQuality()
    private var autoStopReady = false

    // MARK: - Animation

    private var animPhase: CGFloat = 0
    private var displayLink: CADisplayLink?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { displayLink?.invalidate() }

    // MARK: - Public API

    func startAnimation() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func update(progress: Double, quality: MeasurementQuality, autoStopReady: Bool = false) {
        self.scanProgress    = progress
        self.quality         = quality
        self.autoStopReady   = autoStopReady
        setNeedsDisplay()
    }

    @objc private func tick() {
        animPhase += 0.04
        if animPhase > .pi * 2 { animPhase -= .pi * 2 }
        setNeedsDisplay()
    }

    // MARK: - Draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // 반투명 배경
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.26).cgColor)
        ctx.fill(rect)

        // 스캔 가이드 직사각형 (화면 중앙 약간 위)
        let gw = rect.width  * 0.82
        let gh = rect.height * 0.56
        let gx = (rect.width  - gw) / 2
        let gy = (rect.height - gh) / 2 - 18
        let guideRect = CGRect(x: gx, y: gy, width: gw, height: gh)

        // 맥동 글로우
        let pulse = CGFloat(0.10 + 0.08 * abs(sin(animPhase)))
        let glowColor: UIColor = autoStopReady
            ? UIColor(red: 0.20, green: 0.90, blue: 0.20, alpha: pulse)
            : UIColor(red: 0.09, green: 0.47, blue: 0.95, alpha: pulse)
        ctx.setFillColor(glowColor.cgColor)
        ctx.fill(guideRect.insetBy(dx: -12, dy: -12))

        // 가이드 내부 채움 (직사각형 스캔 영역 강조)
        let fillColor: UIColor = autoStopReady
            ? UIColor(red: 0.18, green: 0.75, blue: 0.18, alpha: 0.22)
            : UIColor(red: 0.09, green: 0.47, blue: 0.95, alpha: 0.18)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fill(guideRect)

        // 가이드 테두리 색상
        let borderColor: UIColor = autoStopReady
            ? UIColor(red: 0.20, green: 0.90, blue: 0.20, alpha: 1.0)
            : (quality.overallScore > 0.7
                ? UIColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1.0)
                : UIColor(red: 1.00, green: 0.76, blue: 0.03, alpha: 1.0))
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(guideRect.insetBy(dx: 1.25, dy: 1.25))

        // 나침반 방향 눈금
        drawTickMarks(ctx: ctx, guideRect: guideRect, color: borderColor)

        // 회전 스윕 (자동 종료 전까지)
        if !autoStopReady {
            drawSweep(ctx: ctx, guideRect: guideRect)
        }

        // 진행률 아크
        drawProgressArc(ctx: ctx, guideRect: guideRect)

        // 품질 지표 패널
        drawQualityPanel(ctx: ctx, rect: rect)

        // 자동 종료 배너
        if autoStopReady {
            drawBanner(ctx: ctx, rect: rect,
                       text: "✅ 품질 달성 – 자동 종료 중...",
                       color: UIColor(red: 0.15, green: 0.75, blue: 0.15, alpha: 0.93))
        }
    }

    // MARK: - Sub-draws

    private func drawTickMarks(ctx: CGContext, guideRect: CGRect, color: UIColor) {
        let cx = guideRect.midX, cy = guideRect.midY
        let rx = guideRect.width  / 2
        let ry = guideRect.height / 2
        let len: CGFloat = 22

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)

        // 위
        ctx.move(to: CGPoint(x: cx - len/2, y: cy - ry))
        ctx.addLine(to: CGPoint(x: cx + len/2, y: cy - ry)); ctx.strokePath()
        // 아래
        ctx.move(to: CGPoint(x: cx - len/2, y: cy + ry))
        ctx.addLine(to: CGPoint(x: cx + len/2, y: cy + ry)); ctx.strokePath()
        // 왼
        ctx.move(to: CGPoint(x: cx - rx, y: cy - len/2))
        ctx.addLine(to: CGPoint(x: cx - rx, y: cy + len/2)); ctx.strokePath()
        // 오른
        ctx.move(to: CGPoint(x: cx + rx, y: cy - len/2))
        ctx.addLine(to: CGPoint(x: cx + rx, y: cy + len/2)); ctx.strokePath()
    }

    private func drawSweep(ctx: CGContext, guideRect: CGRect) {
        let cx = guideRect.midX, cy = guideRect.midY
        let rx = guideRect.width  / 2
        let ry = guideRect.height / 2
        let ex = cx + rx * cos(animPhase)
        let ey = cy + ry * sin(animPhase)

        ctx.saveGState()
        ctx.addRect(guideRect)
        ctx.clip()

        guard let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.cyan.withAlphaComponent(0.0).cgColor,
                     UIColor.cyan.withAlphaComponent(0.32).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) else { ctx.restoreGState(); return }

        ctx.drawLinearGradient(grad,
            start: CGPoint(x: cx, y: cy),
            end:   CGPoint(x: ex, y: ey),
            options: [])
        ctx.restoreGState()
    }

    private func drawProgressArc(ctx: CGContext, guideRect: CGRect) {
        guard scanProgress > 0 else { return }
        let center = CGPoint(x: guideRect.midX, y: guideRect.midY)
        let radius = max(guideRect.width, guideRect.height) / 2 + 16
        let startAngle: CGFloat = -.pi / 2
        let endAngle   = startAngle + CGFloat(scanProgress) * 2 * .pi

        ctx.setStrokeColor(UIColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1.0).cgColor)
        ctx.setLineWidth(5.5)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius,
                   startAngle: startAngle, endAngle: endAngle, clockwise: false)
        ctx.strokePath()
    }

    private func drawQualityPanel(ctx: CGContext, rect: CGRect) {
        let items: [(String, Double, UIColor)] = [
            ("신뢰도",  quality.averageConfidence, UIColor(red: 0.40, green: 0.75, blue: 1.00, alpha: 1)),
            ("커버리지", quality.coveragePercent,   UIColor(red: 0.30, green: 0.90, blue: 0.30, alpha: 1)),
            ("안정성",  quality.stabilityScore,    UIColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 1)),
            ("조명",    quality.lightingScore,     UIColor(red: 1.00, green: 0.60, blue: 0.20, alpha: 1)),
            ("기울기",  quality.tiltScore,         UIColor(red: 0.85, green: 0.35, blue: 1.00, alpha: 1)),
        ]

        let panelW: CGFloat = 218
        let rowH:   CGFloat = 25
        let barH:   CGFloat = 8
        let panelH  = CGFloat(items.count) * rowH + 28
        let px: CGFloat = 12
        let py  = rect.height - panelH - 80

        // 패널 배경
        let panelRect = CGRect(x: px, y: py, width: panelW, height: panelH)
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.74).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: panelRect, cornerRadius: 12).cgPath)
        ctx.fillPath()

        // 헤더
        ("스캔 품질" as NSString).draw(
            at: CGPoint(x: px + 12, y: py + 7),
            withAttributes: [
                .font:            UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.55)
            ])

        let labelW: CGFloat  = 54
        let barX    = px + labelW + 8
        let barW    = panelW - labelW - 48

        for (i, (label, value, color)) in items.enumerated() {
            let ry = py + 26 + CGFloat(i) * rowH

            // 레이블
            (label as NSString).draw(
                at: CGPoint(x: px + 12, y: ry + 4),
                withAttributes: [
                    .font:            UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor.white
                ])

            // 바 배경
            let track = CGRect(x: barX, y: ry + (rowH - barH) / 2,
                               width: barW, height: barH).insetBy(dx: 0, dy: 1)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.13).cgColor)
            ctx.fill(track)

            // 바 채움
            let fill = CGRect(x: barX, y: ry + (rowH - barH) / 2,
                              width: CGFloat(min(value, 1.0)) * barW, height: barH).insetBy(dx: 0, dy: 1)
            ctx.setFillColor(color.cgColor)
            ctx.fill(fill)

            // 70% 임계선
            let thX = barX + 0.70 * barW
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to:    CGPoint(x: thX, y: ry + (rowH - barH) / 2 - 3))
            ctx.addLine(to: CGPoint(x: thX, y: ry + (rowH + barH) / 2 + 3))
            ctx.strokePath()

            // 퍼센트
            let pct = String(format: "%2.0f%%", value * 100)
            (pct as NSString).draw(
                at: CGPoint(x: barX + barW + 5, y: ry + 4),
                withAttributes: [
                    .font:            UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.80)
                ])
        }
    }

    private func drawBanner(ctx: CGContext, rect: CGRect, text: String, color: UIColor) {
        let bw: CGFloat = 288, bh: CGFloat = 46
        let bx = (rect.width - bw) / 2
        let by: CGFloat = 84

        ctx.setFillColor(color.cgColor)
        ctx.addPath(UIBezierPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                                 cornerRadius: 15).cgPath)
        ctx.fillPath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            UIFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: bx + (bw - sz.width) / 2, y: by + (bh - sz.height) / 2),
            withAttributes: attrs)
    }
}
