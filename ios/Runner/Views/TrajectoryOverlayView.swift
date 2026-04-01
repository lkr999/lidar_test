import UIKit
import ARKit

/// 스캔 이미지 위에 예측 퍼팅 경로, 30cm 격자, 물 흐름 화살표를 그리는 오버레이
///
/// - 경로: trajectory[0] = 볼 위치, trajectory[last] = 홀 위치 (강제 보정)
/// - 격자: 30cm 간격, 선명한 흰색
/// - 물 흐름 화살표: 각 30cm 교차점에 경사 방향 시안(cyan) 화살표
/// - 투영 모드(ARCamera): 3D → 2D 투영으로 실제 카메라 이미지에 정확히 오버레이
/// - 탑뷰 폴백: 카메라 정보 없을 때 위에서 본 2D 지도
@available(iOS 14.0, *)
class TrajectoryOverlayView: UIView {

    // MARK: - Data

    private var terrain: HeightMapData?
    private var trajectory: [Vector2] = []
    private var ballPos: Vector2    = .zero
    private var holePos: Vector2    = .zero
    private var aimDirection: Vector2 = .zero
    private var arCamera: ARCamera?
    private var viewportSize: CGSize  = .zero

    // 측정 결과 (info panel에 표시)
    private var puttDistance: Double = 0      // meters
    private var breakAmount: Double = 0       // meters
    private var puttSpeed: Double = 0         // m/s
    private var resistancePercent: Double = 50 // 0~100

    // MARK: - Animation

    private var displayLink: CADisplayLink?
    private var animProgress: Double = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { displayLink?.invalidate() }

    // MARK: - Configure

    func configure(terrain: HeightMapData, trajectory: [Vector2],
                   ballPos: Vector2, holePos: Vector2, aimDirection: Vector2,
                   camera: ARCamera? = nil, viewportSize: CGSize = .zero,
                   puttDistance: Double = 0, breakAmount: Double = 0,
                   puttSpeed: Double = 0, resistancePercent: Double = 50) {
        self.terrain      = terrain
        self.trajectory   = trajectory
        self.ballPos      = ballPos
        self.holePos      = holePos
        self.aimDirection = aimDirection
        self.arCamera     = camera
        self.viewportSize = viewportSize
        self.puttDistance  = puttDistance
        self.breakAmount  = breakAmount
        self.puttSpeed    = puttSpeed
        self.resistancePercent = resistancePercent

        animProgress = 0
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        animProgress = min(animProgress + 0.018, 1.0)
        setNeedsDisplay()
        if animProgress >= 1.0 { displayLink?.invalidate(); displayLink = nil }
    }

    // MARK: - Display Trajectory (ball → ... → hole)

    /// 볼 위치를 시작점, 홀 위치를 종점으로 보정한 표시용 경로
    private func makeDisplayTrajectory() -> [Vector2] {
        var pts: [Vector2] = [ballPos]
        for pt in trajectory where hypot(pt.x - ballPos.x, pt.y - ballPos.y) > 0.0005 {
            pts.append(pt)
        }
        if let last = pts.last, hypot(last.x - holePos.x, last.y - holePos.y) > 0.001 {
            pts.append(holePos)
        }
        return pts
    }

    // MARK: - draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let terrain = terrain else { return }

        let disp = makeDisplayTrajectory()

        if arCamera != nil && viewportSize.width > 0 {
            drawProjected(ctx: ctx, rect: rect, terrain: terrain, disp: disp)
        } else {
            drawTopDown(ctx: ctx, rect: rect, terrain: terrain, disp: disp)
        }
    }

    // MARK: - 투영 모드 (ARCamera)

    private func drawProjected(ctx: CGContext, rect: CGRect,
                                terrain: HeightMapData, disp: [Vector2]) {
        // ① 높이 히트맵 + 30cm 격자 + 물 흐름 화살표 (투영)
        drawProjectedHeightMap(ctx: ctx, terrain: terrain)
        drawProjectedGrid(ctx: ctx, terrain: terrain)
        drawProjectedWaterArrows(ctx: ctx, terrain: terrain)

        let endIdx = max(2, Int(Double(disp.count) * animProgress))
        let projPts = (0 ..< min(endIdx, disp.count)).compactMap { gridPosToScreen(disp[$0]) }

        // ② 경로
        if projPts.count >= 2 {
            // glow
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 12,
                          color: UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 0.7).cgColor)
            let glow = UIBezierPath()
            glow.move(to: projPts[0])
            projPts.dropFirst().forEach { glow.addLine(to: $0) }
            ctx.setStrokeColor(UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 0.45).cgColor)
            ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(glow.cgPath); ctx.strokePath()
            ctx.restoreGState()

            // 메인 선
            let main = UIBezierPath()
            main.move(to: projPts[0])
            projPts.dropFirst().forEach { main.addLine(to: $0) }
            ctx.setStrokeColor(UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0).cgColor)
            ctx.setLineWidth(3.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(main.cgPath); ctx.strokePath()

            // 애니메이션 볼
            drawBallMarker(ctx: ctx, at: projPts.last!, radius: 8)
        }

        // ③ 홀 마커 (start = 볼, end = 홀)
        if let holeScr = gridPosToScreen(holePos) { drawHoleMarker(ctx: ctx, at: holeScr) }

        // ④ 볼 시작 마커 + 에임 화살표 (볼 → 홀 방향 → 50cm 연장)
        if let ballScr = gridPosToScreen(ballPos) {
            drawStartMarker(ctx: ctx, at: ballScr)
            let aimEndWorld = aimEndPoint()
            if let aimScr = gridPosToScreen(aimEndWorld) { drawAimArrow(ctx: ctx, from: ballScr, to: aimScr) }
        }

        drawInfoLabels(ctx: ctx, rect: rect)
    }

    // MARK: - 탑뷰 폴백 모드

    private func drawTopDown(ctx: CGContext, rect: CGRect,
                              terrain: HeightMapData, disp: [Vector2]) {
        let tw = Double(terrain.gridWidth)  * terrain.cellSize
        let th = Double(terrain.gridHeight) * terrain.cellSize
        let sx = min(rect.width / CGFloat(tw), rect.height / CGFloat(th))
        let ox = (rect.width  - CGFloat(tw) * sx) / 2
        let oy = (rect.height - CGFloat(th) * sx) / 2

        func cvt(_ v: Vector2) -> CGPoint {
            CGPoint(x: CGFloat(v.x) * sx + ox, y: CGFloat(v.y) * sx + oy)
        }

        ctx.setFillColor(UIColor.black.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)

        // ① 높이 히트맵
        drawHeightMapOverlay(ctx: ctx, terrain: terrain, sx: sx, ox: ox, oy: oy)

        // ② 30cm 격자 + 물 흐름 화살표
        drawGridAndWaterFlow(ctx: ctx, terrain: terrain, sx: sx, ox: ox, oy: oy)

        // ③ 등고선
        drawContourLines(ctx: ctx, terrain: terrain, sx: sx, ox: ox, oy: oy)

        // ④ 홀 마커
        drawHoleMarker(ctx: ctx, at: cvt(holePos))

        // ⑤ 경로
        let endIdx = max(2, Int(Double(disp.count) * animProgress))
        let visCount = min(endIdx, disp.count)
        if visCount >= 2 {
            // glow
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10,
                          color: UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 0.6).cgColor)
            let glow = UIBezierPath()
            glow.move(to: cvt(disp[0]))
            (1 ..< visCount).forEach { glow.addLine(to: cvt(disp[$0])) }
            ctx.setStrokeColor(UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 0.4).cgColor)
            ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(glow.cgPath); ctx.strokePath()
            ctx.restoreGState()

            let main = UIBezierPath()
            main.move(to: cvt(disp[0]))
            (1 ..< visCount).forEach { main.addLine(to: cvt(disp[$0])) }
            ctx.setStrokeColor(UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0).cgColor)
            ctx.setLineWidth(3.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(main.cgPath); ctx.strokePath()

            drawBallMarker(ctx: ctx, at: cvt(disp[visCount - 1]), radius: 8)
        }

        // ⑥ 볼 시작 마커 + 에임 화살표 (볼 → 홀 방향 → 50cm 연장)
        let ballScr = cvt(ballPos)
        drawStartMarker(ctx: ctx, at: ballScr)
        let aimEndWorld = aimEndPoint()
        drawAimArrow(ctx: ctx, from: ballScr, to: cvt(aimEndWorld))

        drawInfoLabels(ctx: ctx, rect: rect)
    }

    // MARK: - 높이 히트맵 (탑뷰)

    private func drawHeightMapOverlay(ctx: CGContext, terrain: HeightMapData,
                                       sx: CGFloat, ox: CGFloat, oy: CGFloat) {
        let minH = terrain.minHeight, maxH = terrain.maxHeight
        let range = max(maxH - minH, 0.0001)
        let cs = terrain.cellSize * Double(sx)
        let step = max(1, Int(2.0 / cs))

        for y in stride(from: 0, to: terrain.gridHeight, by: step) {
            for x in stride(from: 0, to: terrain.gridWidth, by: step) {
                let t = (terrain.getHeight(x: x, y: y) - minH) / range
                ctx.setFillColor(heightColor(t: t).withAlphaComponent(0.55).cgColor)
                ctx.fill(CGRect(
                    x: CGFloat(Double(x) * terrain.cellSize) * sx + ox,
                    y: CGFloat(Double(y) * terrain.cellSize) * sx + oy,
                    width:  CGFloat(cs * Double(step) + 1),
                    height: CGFloat(cs * Double(step) + 1)
                ))
            }
        }
    }

    // MARK: - 30cm 격자 + 경사 강도 색상 물 흐름 화살표 (탑뷰)

    private func drawGridAndWaterFlow(ctx: CGContext, terrain: HeightMapData,
                                       sx: CGFloat, ox: CGFloat, oy: CGFloat) {
        let spacing = 0.30  // 30cm
        let tw = Double(terrain.gridWidth)  * terrain.cellSize
        let th = Double(terrain.gridHeight) * terrain.cellSize

        // 격자선 — 이중 스트로크
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(2.0)

        var xi = 0.0
        while xi <= tw + 0.0001 {
            let cxp = CGFloat(xi) * sx + ox
            ctx.move(to: CGPoint(x: cxp, y: oy))
            ctx.addLine(to: CGPoint(x: cxp, y: CGFloat(th) * sx + oy))
            ctx.strokePath()
            xi += spacing
        }
        var yi = 0.0
        while yi <= th + 0.0001 {
            let cyp = CGFloat(yi) * sx + oy
            ctx.move(to: CGPoint(x: ox, y: cyp))
            ctx.addLine(to: CGPoint(x: CGFloat(tw) * sx + ox, y: cyp))
            ctx.strokePath()
            yi += spacing
        }

        // 최대 경사 크기 사전 계산 (색상 정규화용)
        let slopeInfo = TerrainAnalyzer.calculateSlopeMagnitudeMap(terrain: terrain, spacing: spacing)
        let maxSlope = slopeInfo.maxSlope

        let maxLen = CGFloat(spacing) * sx * 0.40

        var gy = spacing
        while gy < th - 0.0001 {
            var gx = spacing
            while gx < tw - 0.0001 {
                let cxi = Int(gx / terrain.cellSize)
                let cyi = Int(gy / terrain.cellSize)
                let slope = TerrainAnalyzer.calculateHighPrecisionSlope(terrain: terrain, x: cxi, y: cyi)
                let mag = slope.length
                if mag > 0.003 {
                    // 경사 크기에 따른 색상: 초록(완만) → 노랑(중간) → 빨강(급경사)
                    let slopeRatio = min(mag / maxSlope, 1.0)
                    let arrowColor = slopeGradientColor(ratio: slopeRatio)
                    ctx.setFillColor(arrowColor.cgColor)
                    ctx.setStrokeColor(arrowColor.cgColor)

                    let norm = slope.normalized()
                    let arrowLen = min(CGFloat(mag) * 450.0, maxLen)
                    let from = CGPoint(x: CGFloat(gx) * sx + ox, y: CGFloat(gy) * sx + oy)
                    let to   = CGPoint(x: from.x + CGFloat(norm.x) * arrowLen,
                                       y: from.y + CGFloat(norm.y) * arrowLen)
                    drawArrow(ctx: ctx, from: from, to: to, headFraction: 0.38)
                }
                gx += spacing
            }
            gy += spacing
        }
    }

    // MARK: - 높이 히트맵 투영 (카메라 모드)

    private func drawProjectedHeightMap(ctx: CGContext, terrain: HeightMapData) {
        let minH = terrain.minHeight, maxH = terrain.maxHeight
        let range = max(maxH - minH, 0.0001)
        let spacing = 0.30  // 30cm 셀 단위
        let tw = Double(terrain.gridWidth)  * terrain.cellSize
        let th = Double(terrain.gridHeight) * terrain.cellSize

        var gy = 0.0
        while gy < th - 0.0001 {
            var gx = 0.0
            while gx < tw - 0.0001 {
                let cx = Int((gx + spacing / 2) / terrain.cellSize)
                let cy = Int((gy + spacing / 2) / terrain.cellSize)
                let clampX = max(0, min(cx, terrain.gridWidth - 1))
                let clampY = max(0, min(cy, terrain.gridHeight - 1))
                let h = terrain.getHeight(x: clampX, y: clampY)
                let t = (h - minH) / range

                // 셀의 4 꼭짓점을 투영
                let corners = [
                    Vector2(x: gx, y: gy),
                    Vector2(x: min(gx + spacing, tw), y: gy),
                    Vector2(x: min(gx + spacing, tw), y: min(gy + spacing, th)),
                    Vector2(x: gx, y: min(gy + spacing, th))
                ]
                let scrCorners = corners.compactMap { gridPosToScreen($0) }
                if scrCorners.count == 4 {
                    let path = UIBezierPath()
                    path.move(to: scrCorners[0])
                    for i in 1..<4 { path.addLine(to: scrCorners[i]) }
                    path.close()
                    ctx.setFillColor(heightColor(t: t).withAlphaComponent(0.55).cgColor)
                    ctx.addPath(path.cgPath)
                    ctx.fillPath()
                }
                gx += spacing
            }
            gy += spacing
        }
    }

    // MARK: - 30cm 격자 투영 (카메라 모드)

    private func drawProjectedGrid(ctx: CGContext, terrain: HeightMapData) {
        let spacing = 0.30
        let tw = Double(terrain.gridWidth)  * terrain.cellSize
        let th = Double(terrain.gridHeight) * terrain.cellSize
        let sampleStep = terrain.cellSize * 8  // 8cm 간격 샘플링

        // 이중 스트로크: 어두운 외곽선 + 흰 내선 → 어떤 배경에서도 선명하게
        for pass in 0..<2 {
            if pass == 0 {
                ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.60).cgColor)
                ctx.setLineWidth(2.4)
            } else {
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.75).cgColor)
                ctx.setLineWidth(1.0)
            }

            // 가로선 (y 고정, x 변화)
            var yi = 0.0
            while yi <= th + 0.0001 {
                var xi = 0.0; var isFirst = true
                while xi <= tw + 0.0001 {
                    if let scr = gridPosToScreen(Vector2(x: xi, y: yi)) {
                        if isFirst { ctx.move(to: scr); isFirst = false } else { ctx.addLine(to: scr) }
                    } else if !isFirst { ctx.strokePath(); isFirst = true }
                    xi += sampleStep
                }
                if !isFirst { ctx.strokePath() }
                yi += spacing
            }

            // 세로선 (x 고정, y 변화)
            var xi = 0.0
            while xi <= tw + 0.0001 {
                var yi = 0.0; var isFirst = true
                while yi <= th + 0.0001 {
                    if let scr = gridPosToScreen(Vector2(x: xi, y: yi)) {
                        if isFirst { ctx.move(to: scr); isFirst = false } else { ctx.addLine(to: scr) }
                    } else if !isFirst { ctx.strokePath(); isFirst = true }
                    yi += sampleStep
                }
                if !isFirst { ctx.strokePath() }
                xi += spacing
            }
        }
    }

    // MARK: - 경사 강도 색상 물 흐름 화살표 투영 (카메라 모드)

    private func drawProjectedWaterArrows(ctx: CGContext, terrain: HeightMapData) {
        let spacing = 0.30
        let tw = Double(terrain.gridWidth)  * terrain.cellSize
        let th = Double(terrain.gridHeight) * terrain.cellSize

        // 최대 경사 크기 (색상 정규화)
        let slopeInfo = TerrainAnalyzer.calculateSlopeMagnitudeMap(terrain: terrain, spacing: spacing)
        let maxSlope = slopeInfo.maxSlope

        var gy = spacing
        while gy < th - 0.0001 {
            var gx = spacing
            while gx < tw - 0.0001 {
                let cxi = Int(gx / terrain.cellSize)
                let cyi = Int(gy / terrain.cellSize)
                let slope = TerrainAnalyzer.calculateHighPrecisionSlope(terrain: terrain, x: cxi, y: cyi)
                let mag = slope.length
                if mag > 0.003, let center = gridPosToScreen(Vector2(x: gx, y: gy)) {
                    // 경사 강도 색상 (초록→노랑→빨강)
                    let slopeRatio = min(mag / maxSlope, 1.0)
                    let arrowColor = slopeGradientColor(ratio: slopeRatio)
                    ctx.setFillColor(arrowColor.cgColor)
                    ctx.setStrokeColor(arrowColor.cgColor)

                    let arrowM = min(mag * 5, 0.12)
                    let norm = slope.normalized()
                    let tipGrid = Vector2(x: gx + norm.x * arrowM, y: gy + norm.y * arrowM)
                    if let tip = gridPosToScreen(tipGrid) {
                        drawArrow(ctx: ctx, from: center, to: tip, headFraction: 0.38)
                    }
                }
                gx += spacing
            }
            gy += spacing
        }
    }

    // MARK: - 등고선 (탑뷰) — 절대 높이 기준 1cm 간격 + 레이블

    private func drawContourLines(ctx: CGContext, terrain: HeightMapData,
                                   sx: CGFloat, ox: CGFloat, oy: CGFloat) {
        let minH = terrain.minHeight, maxH = terrain.maxHeight
        // 절대 높이 기준 1cm 간격 등고선
        let contourInterval = 0.01  // 1cm
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.9)
        let step = 2

        var level = (minH / contourInterval).rounded(.down) * contourInterval
        while level <= maxH {
            // 주 등고선 (5cm 간격)은 더 굵게
            let isMajor = abs(level.remainder(dividingBy: 0.05)) < 0.001
            ctx.setLineWidth(isMajor ? 1.6 : 0.7)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(isMajor ? 0.55 : 0.30).cgColor)

            var firstPtForLabel: CGPoint? = nil

            for y in stride(from: 0, to: terrain.gridHeight - 1, by: step) {
                for x in stride(from: 0, to: terrain.gridWidth - 1, by: step) {
                    let h00 = terrain.getHeight(x: x, y: y)
                    let h10 = terrain.getHeight(x: x + step, y: y)
                    let h01 = terrain.getHeight(x: x, y: y + step)
                    let h11 = terrain.getHeight(x: x + step, y: y + step)
                    var pts: [CGPoint] = []
                    func add(_ ax: Double, _ ay: Double) {
                        pts.append(CGPoint(x: CGFloat(ax) * sx + ox, y: CGFloat(ay) * sx + oy))
                    }
                    if (h00-level)*(h10-level) < 0 {
                        let t = (level-h00)/(h10-h00)
                        add((Double(x)+t*Double(step))*terrain.cellSize, Double(y)*terrain.cellSize)
                    }
                    if (h10-level)*(h11-level) < 0 {
                        let t = (level-h10)/(h11-h10)
                        add(Double(x+step)*terrain.cellSize, (Double(y)+t*Double(step))*terrain.cellSize)
                    }
                    if (h01-level)*(h11-level) < 0 {
                        let t = (level-h01)/(h11-h01)
                        add((Double(x)+t*Double(step))*terrain.cellSize, Double(y+step)*terrain.cellSize)
                    }
                    if (h00-level)*(h01-level) < 0 {
                        let t = (level-h00)/(h01-h00)
                        add(Double(x)*terrain.cellSize, (Double(y)+t*Double(step))*terrain.cellSize)
                    }
                    if pts.count >= 2 {
                        ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.strokePath()
                        if isMajor && firstPtForLabel == nil { firstPtForLabel = pts[0] }
                    }
                }
            }

            // 주 등고선에 높이 레이블 (cm 단위)
            if isMajor, let labelPt = firstPtForLabel {
                let heightCm = (level - terrain.groundY) * 100.0
                let label = String(format: "%.1fcm", heightCm)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.70),
                    .backgroundColor: UIColor.black.withAlphaComponent(0.45)
                ]
                (label as NSString).draw(at: CGPoint(x: labelPt.x + 2, y: labelPt.y - 10), withAttributes: attrs)
            }

            level += contourInterval
        }
    }

    // MARK: - 마커

    private func drawHoleMarker(ctx: CGContext, at p: CGPoint) {
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x-12, y: p.y-12, width: 24, height: 24))
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: p.x-12, y: p.y-12, width: 24, height: 24))
        // 깃발
        ctx.setStrokeColor(UIColor.red.cgColor); ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: p.x, y: p.y-12)); ctx.addLine(to: CGPoint(x: p.x, y: p.y-42))
        ctx.strokePath()
        let flag = UIBezierPath()
        flag.move(to: CGPoint(x: p.x, y: p.y-42))
        flag.addLine(to: CGPoint(x: p.x+20, y: p.y-35))
        flag.addLine(to: CGPoint(x: p.x, y: p.y-28))
        flag.close()
        ctx.setFillColor(UIColor.red.cgColor); ctx.addPath(flag.cgPath); ctx.fillPath()
    }

    private func drawStartMarker(ctx: CGContext, at p: CGPoint) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x-11, y: p.y-11, width: 22, height: 22))
        ctx.setStrokeColor(UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 1).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: p.x-11, y: p.y-11, width: 22, height: 22))
    }

    private func drawBallMarker(ctx: CGContext, at p: CGPoint, radius: CGFloat) {
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.25).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x-radius-1, y: p.y-radius+2, width: (radius+1)*2, height: (radius+1)*2))
        guard let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.white.cgColor, UIColor(white: 0.82, alpha: 1).cgColor] as CFArray,
            locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2))
        ctx.clip()
        ctx.drawRadialGradient(grad,
            startCenter: CGPoint(x: p.x-radius*0.25, y: p.y-radius*0.25), startRadius: 0,
            endCenter: p, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// 에임 방향 종점 계산: ballPos → aimDirection으로 홀을 50cm 지난 지점
    private func aimEndPoint() -> Vector2 {
        let toHole = holePos - ballPos
        // aimDirection 방향으로 홀까지의 투영 거리
        let dAlongAim = toHole.dot(aimDirection)
        // 홀보다 50cm 더 멀리, 최소 0.4m 보장
        let totalDist = max(dAlongAim, 0.4) + 0.5
        return ballPos + aimDirection * totalDist
    }

    /// 붉은 점선 에임 화살표 (볼 → 홀 방향으로 50cm 연장)
    private func drawAimArrow(ctx: CGContext, from: CGPoint, to: CGPoint) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 14 else { return }

        let nx = dx / len, ny = dy / len

        // 붉은 점선 샤프트
        ctx.setStrokeColor(UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.92).cgColor)
        ctx.setLineWidth(2.8)
        ctx.setLineDash(phase: 0, lengths: [11, 6])
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // 화살촉 (채운 삼각형)
        let headLen: CGFloat = 20
        let headW:   CGFloat = 10
        let base = CGPoint(x: to.x - nx * headLen, y: to.y - ny * headLen)
        let tri  = UIBezierPath()
        tri.move(to: to)
        tri.addLine(to: CGPoint(x: base.x + ny * headW, y: base.y - nx * headW))
        tri.addLine(to: CGPoint(x: base.x - ny * headW, y: base.y + nx * headW))
        tri.close()
        ctx.setFillColor(UIColor(red: 1.0, green: 0.10, blue: 0.10, alpha: 1.0).cgColor)
        ctx.addPath(tri.cgPath)
        ctx.fillPath()

        // 시작점 원 (볼 위치 강조)
        ctx.setFillColor(UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: from.x - 5.5, y: from.y - 5.5, width: 11, height: 11))
    }

    // MARK: - 화살표

    private func drawArrow(ctx: CGContext, from: CGPoint, to: CGPoint, headFraction: CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = sqrt(dx*dx + dy*dy)
        guard len > 5 else { return }
        let nx = dx/len, ny = dy/len
        let headLen = len * headFraction
        let shaftEnd = CGPoint(x: to.x - nx*headLen, y: to.y - ny*headLen)

        ctx.setLineWidth(1.6)
        ctx.move(to: from); ctx.addLine(to: shaftEnd); ctx.strokePath()

        let pw = headLen * 0.46
        let tri = UIBezierPath()
        tri.move(to: to)
        tri.addLine(to: CGPoint(x: shaftEnd.x + ny*pw, y: shaftEnd.y - nx*pw))
        tri.addLine(to: CGPoint(x: shaftEnd.x - ny*pw, y: shaftEnd.y + nx*pw))
        tri.close()
        ctx.addPath(tri.cgPath); ctx.fillPath()
    }

    // MARK: - 정보 라벨

    private func drawInfoLabels(ctx: CGContext, rect: CGRect) {
        guard let terrain = terrain else { return }
        let ballGX = min(terrain.gridWidth  - 1, max(0, Int(ballPos.x / terrain.cellSize)))
        let ballGY = min(terrain.gridHeight - 1, max(0, Int(ballPos.y / terrain.cellSize)))
        let holeGX = min(terrain.gridWidth  - 1, max(0, Int(holePos.x / terrain.cellSize)))
        let holeGY = min(terrain.gridHeight - 1, max(0, Int(holePos.y / terrain.cellSize)))
        let heightDiffM = terrain.getHeight(x: holeGX, y: holeGY)
                        - terrain.getHeight(x: ballGX, y: ballGY)

        let boxW: CGFloat = 195, boxH: CGFloat = 118
        // 상단 상태바(~70pt) 아래에 배치
        let safeTop = self.safeAreaInsets.top
        let box = CGRect(x: rect.width - boxW - 12, y: safeTop + 68, width: boxW, height: boxH)
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: 12).cgPath)
        ctx.fillPath()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.55)
        ]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1)
        ]

        let tx = box.minX + 10
        var ty: CGFloat = box.minY + 8

        ("측정 결과" as NSString).draw(at: CGPoint(x: tx, y: ty), withAttributes: titleAttrs)
        ty += 16

        (String(format: "거리: %.2f m", puttDistance) as NSString)
            .draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)
        ty += 18

        (String(format: "브레이크: %.2f m", breakAmount) as NSString)
            .draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)
        ty += 18

        (String(format: "속도: %.2f m/s", puttSpeed) as NSString)
            .draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)
        ty += 18

        let diffSymbol = heightDiffM >= 0 ? "↑" : "↓"
        (String(format: "높이차: %@%.2fm", diffSymbol, abs(heightDiffM)) as NSString)
            .draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)
        ty += 18

        (String(format: "저항: %.0f%%", resistancePercent) as NSString)
            .draw(at: CGPoint(x: tx, y: ty), withAttributes: valAttrs)
    }

    // MARK: - 좌표 변환 (투영 모드)

    private func gridToWorld3D(_ pos: Vector2) -> SIMD3<Float>? {
        guard let t = terrain else { return nil }
        let rx = Double(t.gridWidth)  * t.cellSize / 2.0
        let rz = Double(t.gridHeight) * t.cellSize / 2.0
        let gx = min(t.gridWidth  - 1, max(0, Int(pos.x / t.cellSize)))
        let gy = min(t.gridHeight - 1, max(0, Int(pos.y / t.cellSize)))
        // 그리드 원점(originX/Z) 기반 월드 좌표 변환
        return SIMD3<Float>(Float(pos.x - rx + t.originX),
                            Float(t.getHeight(x: gx, y: gy)),
                            Float(pos.y - rz + t.originZ))
    }

    private func projectToScreen(_ world: SIMD3<Float>) -> CGPoint? {
        guard let camera = arCamera, viewportSize.width > 0 else { return nil }
        let camSpace = camera.transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1.0)
        guard camSpace.z < 0 else { return nil }
        let ori: UIInterfaceOrientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            .map { $0.interfaceOrientation } ?? .portrait
        let scr = camera.projectPoint(world, orientation: ori, viewportSize: viewportSize)
        guard scr.x >= -60, scr.x <= viewportSize.width + 60,
              scr.y >= -60, scr.y <= viewportSize.height + 60 else { return nil }
        return scr
    }

    private func gridPosToScreen(_ pos: Vector2) -> CGPoint? {
        guard let w = gridToWorld3D(pos) else { return nil }
        return projectToScreen(w)
    }

    // MARK: - 색상

    private func heightColor(t: Double) -> UIColor {
        let clr: [(Double, UIColor)] = [
            (0.0, UIColor(red: 0.106, green: 0.369, blue: 0.125, alpha: 1)),
            (0.33, UIColor(red: 0.298, green: 0.686, blue: 0.314, alpha: 1)),
            (0.66, UIColor(red: 0.804, green: 0.863, blue: 0.224, alpha: 1)),
            (1.0, UIColor(red: 0.957, green: 0.263, blue: 0.212, alpha: 1))
        ]
        let tc = max(0, min(1, t))
        for i in 1 ..< clr.count {
            if tc <= clr[i].0 {
                let lo = clr[i-1]; let hi = clr[i]
                let f = (tc - lo.0) / (hi.0 - lo.0)
                return lerpColor(lo.1, hi.1, f: f)
            }
        }
        return clr.last!.1
    }

    private func lerpColor(_ a: UIColor, _ b: UIColor, f: Double) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(max(0, min(1, f)))
        return UIColor(red: r1+(r2-r1)*t, green: g1+(g2-g1)*t,
                       blue: b1+(b2-b1)*t, alpha: a1+(a2-a1)*t)
    }

    /// 경사 크기 비율에 따른 그라데이션 색상
    /// ratio 0.0 → 초록(완만), 0.5 → 노랑(중간), 1.0 → 빨강(급경사)
    private func slopeGradientColor(ratio: Double) -> UIColor {
        let r = max(0, min(1, ratio))
        if r < 0.5 {
            // 초록 → 노랑
            let t = r / 0.5
            return UIColor(red: CGFloat(t), green: CGFloat(0.85), blue: CGFloat(0.15 * (1-t)), alpha: 0.90)
        } else {
            // 노랑 → 빨강
            let t = (r - 0.5) / 0.5
            return UIColor(red: CGFloat(1.0), green: CGFloat(0.85 * (1-t)), blue: 0, alpha: 0.90)
        }
    }
}
