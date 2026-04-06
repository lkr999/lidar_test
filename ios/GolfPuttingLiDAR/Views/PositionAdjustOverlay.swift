import UIKit

// MARK: - PositionAdjustOverlay
/// 볼/홀 위치를 드래그·방향키로 미세조정하고 확정하는 전체화면 오버레이
class PositionAdjustOverlay: UIView {

    // MARK: - Public API
    var onConfirm: ((CGPoint) -> Void)?
    var onCancel:  (() -> Void)?
    private(set) var currentPosition: CGPoint

    // MARK: - Sub-views
    private let dimView       = UIView()         // 반투명 배경
    private let spotlightLayer = CAShapeLayer()  // 크로스헤어 주변 spotlight
    private let crosshairView  = CrosshairView()
    private let markerLabel    = UILabel()       // "볼" / "홀"
    private let titleLabel     = UILabel()
    private let controlPanel   = UIView()
    private let confirmButton  = UIButton(type: .system)
    private let cancelButton   = UIButton(type: .system)

    // 감지된 원 하이라이트용
    private var highlightViews: [UIView] = []

    private let markerName: String   // "볼" 또는 "홀"
    private let accentColor: UIColor

    // MARK: - Init
    init(frame: CGRect, markerName: String, initialPosition: CGPoint) {
        self.markerName       = markerName
        self.currentPosition  = initialPosition
        self.accentColor      = markerName == "볼" ? .white : UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
        super.init(frame: frame)
        setupViews()
        moveCrosshair(to: initialPosition, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public Methods

    /// 감지된 원들을 하이라이트 링으로 표시
    func showDetectedCircles(_ circles: [DetectedCircle]) {
        highlightViews.forEach { $0.removeFromSuperview() }
        highlightViews = []

        for (i, circle) in circles.enumerated() {
            let ring = DetectionRingView(circle: circle, index: i)
            ring.onTap = { [weak self] in
                self?.moveCrosshair(to: circle.center, animated: true)
            }
            insertSubview(ring, belowSubview: crosshairView)
            highlightViews.append(ring)
        }
    }

    // MARK: - Setup
    private func setupViews() {
        // 딤 배경 (밝기 개선: 0.45 → 0.2)
        dimView.frame           = bounds
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(dimView)

        // Spotlight 레이어 (크로스헤어 주변만 밝게, alpha 낮춤)
        spotlightLayer.fillRule  = .evenOdd
        spotlightLayer.fillColor = UIColor.black.withAlphaComponent(0.25).cgColor
        dimView.layer.addSublayer(spotlightLayer)

        // 타이틀
        titleLabel.text          = "\(markerName) 위치 조정"
        titleLabel.font          = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor     = .white
        titleLabel.textAlignment = .center
        titleLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        titleLabel.layer.cornerRadius = 10; titleLabel.clipsToBounds = true
        addSubview(titleLabel)

        // 크로스헤어
        crosshairView.color = accentColor
        crosshairView.label = markerName
        addSubview(crosshairView)

        // 마커 라벨 (크로스헤어 아래)
        markerLabel.text          = markerName
        markerLabel.font          = .systemFont(ofSize: 12, weight: .bold)
        markerLabel.textColor     = accentColor
        markerLabel.textAlignment = .center
        addSubview(markerLabel)

        // 컨트롤 패널
        setupControlPanel()

        // 타이틀 레이아웃
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 70),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            titleLabel.heightAnchor.constraint(equalToConstant: 36),
        ])

        // 드래그 제스처
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        crosshairView.addGestureRecognizer(pan)
        crosshairView.isUserInteractionEnabled = true

        // 배경 탭 → 크로스헤어 이동
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        dimView.addGestureRecognizer(tap)
    }

    private func setupControlPanel() {
        controlPanel.backgroundColor    = UIColor.black.withAlphaComponent(0.85)
        controlPanel.layer.cornerRadius = 20
        controlPanel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        controlPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlPanel)

        NSLayoutConstraint.activate([
            controlPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
            controlPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlPanel.heightAnchor.constraint(equalToConstant: 190),
        ])

        // 힌트 라벨
        let hint = UILabel()
        hint.text          = "드래그하거나 방향 버튼으로 위치를 조정하세요"
        hint.font          = .systemFont(ofSize: 13)
        hint.textColor     = UIColor.white.withAlphaComponent(0.7)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        controlPanel.addSubview(hint)

        // 4방향 타원 버튼
        let dpad = buildDirectionPad()
        dpad.translatesAutoresizingMaskIntoConstraints = false
        controlPanel.addSubview(dpad)

        // 확정 / 취소 버튼
        confirmButton.setTitle("✓  확정", for: .normal)
        confirmButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.backgroundColor   = accentColor == .white
            ? UIColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)
            : UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        confirmButton.layer.cornerRadius = 14
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.setTitle("취소", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 14)
        cancelButton.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        controlPanel.addSubview(confirmButton)
        controlPanel.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: controlPanel.topAnchor, constant: 14),
            hint.centerXAnchor.constraint(equalTo: controlPanel.centerXAnchor),

            dpad.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
            dpad.centerXAnchor.constraint(equalTo: controlPanel.centerXAnchor),
            dpad.widthAnchor.constraint(equalToConstant: 90),
            dpad.heightAnchor.constraint(equalToConstant: 60),

            confirmButton.topAnchor.constraint(equalTo: dpad.bottomAnchor, constant: 14),
            confirmButton.centerXAnchor.constraint(equalTo: controlPanel.centerXAnchor),
            confirmButton.widthAnchor.constraint(equalToConstant: 160),
            confirmButton.heightAnchor.constraint(equalToConstant: 44),

            cancelButton.topAnchor.constraint(equalTo: confirmButton.bottomAnchor, constant: 6),
            cancelButton.centerXAnchor.constraint(equalTo: controlPanel.centerXAnchor),
        ])
    }

    /// 하나의 반투명 타원 안에 4개 방향 버튼 배치
    /// 타원 크기: 90×60 (이전 대비 절반)
    private func buildDirectionPad() -> UIView {
        let step: CGFloat = 8

        // 반투명 타원 컨테이너
        let oval = UIView()
        oval.backgroundColor    = UIColor.white.withAlphaComponent(0.12)
        oval.layer.cornerRadius = 30          // 높이(60)의 절반 → 완전한 가로 타원
        oval.layer.borderWidth  = 1
        oval.layer.borderColor  = UIColor.white.withAlphaComponent(0.30).cgColor
        oval.clipsToBounds      = true

        let upBtn    = makeOvalDirButton(symbol: "chevron.up",    dx: 0,     dy: -step)
        let downBtn  = makeOvalDirButton(symbol: "chevron.down",  dx: 0,     dy:  step)
        let leftBtn  = makeOvalDirButton(symbol: "chevron.left",  dx: -step, dy:  0)
        let rightBtn = makeOvalDirButton(symbol: "chevron.right", dx:  step, dy:  0)

        for btn in [upBtn, downBtn, leftBtn, rightBtn] {
            btn.translatesAutoresizingMaskIntoConstraints = false
            oval.addSubview(btn)
        }

        let bS: CGFloat = 26   // 버튼 터치 영역 (정사각형)

        NSLayoutConstraint.activate([
            // 위 – 상단 중앙 안쪽
            upBtn.centerXAnchor.constraint(equalTo: oval.centerXAnchor),
            upBtn.topAnchor.constraint(equalTo: oval.topAnchor, constant: 2),
            upBtn.widthAnchor.constraint(equalToConstant: bS),
            upBtn.heightAnchor.constraint(equalToConstant: bS),

            // 아래 – 하단 중앙 안쪽
            downBtn.centerXAnchor.constraint(equalTo: oval.centerXAnchor),
            downBtn.bottomAnchor.constraint(equalTo: oval.bottomAnchor, constant: -2),
            downBtn.widthAnchor.constraint(equalToConstant: bS),
            downBtn.heightAnchor.constraint(equalToConstant: bS),

            // 왼쪽 – 좌측 중앙 안쪽
            leftBtn.leadingAnchor.constraint(equalTo: oval.leadingAnchor, constant: 4),
            leftBtn.centerYAnchor.constraint(equalTo: oval.centerYAnchor),
            leftBtn.widthAnchor.constraint(equalToConstant: bS),
            leftBtn.heightAnchor.constraint(equalToConstant: bS),

            // 오른쪽 – 우측 중앙 안쪽
            rightBtn.trailingAnchor.constraint(equalTo: oval.trailingAnchor, constant: -4),
            rightBtn.centerYAnchor.constraint(equalTo: oval.centerYAnchor),
            rightBtn.widthAnchor.constraint(equalToConstant: bS),
            rightBtn.heightAnchor.constraint(equalToConstant: bS),
        ])

        return oval
    }

    /// 타원 내부용 방향 버튼 (배경 없음, 흰색 chevron 아이콘)
    private func makeOvalDirButton(symbol: String, dx: CGFloat, dy: CGFloat) -> UIButton {
        let btn = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        btn.tintColor       = UIColor.white.withAlphaComponent(0.85)
        btn.backgroundColor = .clear

        btn.addTarget(self, action: #selector(dirButtonHighlight(_:)), for: .touchDown)
        btn.addTarget(self, action: #selector(dirButtonRestore(_:)),
                      for: [.touchUpInside, .touchUpOutside, .touchCancel])

        btn.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.moveCrosshair(to: CGPoint(x: self.currentPosition.x + dx,
                                           y: self.currentPosition.y + dy),
                               animated: false)
        }, for: .touchUpInside)
        return btn
    }

    @objc private func dirButtonHighlight(_ btn: UIButton) {
        UIView.animate(withDuration: 0.07) {
            btn.tintColor = .white
            btn.transform = CGAffineTransform(scaleX: 0.80, y: 0.80)
        }
    }

    @objc private func dirButtonRestore(_ btn: UIButton) {
        UIView.animate(withDuration: 0.12) {
            btn.tintColor = UIColor.white.withAlphaComponent(0.85)
            btn.transform = .identity
        }
    }

    // MARK: - Crosshair Movement
    private func moveCrosshair(to point: CGPoint, animated: Bool) {
        let clamped = CGPoint(
            x: max(40, min(bounds.width  - 40, point.x)),
            y: max(40, min(bounds.height - 240, point.y))
        )
        currentPosition = clamped

        let size: CGFloat = 80
        let frame = CGRect(x: clamped.x - size/2, y: clamped.y - size/2, width: size, height: size)

        if animated {
            UIView.animate(withDuration: 0.18) {
                self.crosshairView.frame = frame
                self.markerLabel.frame   = CGRect(x: clamped.x - 20, y: clamped.y + size/2 + 4, width: 40, height: 18)
            }
        } else {
            crosshairView.frame = frame
            markerLabel.frame   = CGRect(x: clamped.x - 20, y: clamped.y + size/2 + 4, width: 40, height: 18)
        }
        updateSpotlight(at: clamped)
    }

    private func updateSpotlight(at center: CGPoint) {
        let radius: CGFloat = 60
        let outerPath = UIBezierPath(rect: bounds)
        let holePath  = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2))
        outerPath.append(holePath)
        spotlightLayer.path = outerPath.cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spotlightLayer.frame = bounds
        updateSpotlight(at: currentPosition)
    }

    // MARK: - Gesture Handlers
    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        moveCrosshair(to: CGPoint(x: currentPosition.x + t.x, y: currentPosition.y + t.y), animated: false)
        g.setTranslation(.zero, in: self)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        moveCrosshair(to: g.location(in: self), animated: true)
    }

    // MARK: - Button Actions
    @objc private func confirmTapped() {
        onConfirm?(currentPosition)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}

// MARK: - CrosshairView
private class CrosshairView: UIView {
    var color: UIColor = .white { didSet { setNeedsDisplay() } }
    var label: String  = "볼"   { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let cx = rect.midX, cy = rect.midY
        let r1: CGFloat = 30, r2: CGFloat = 8

        // Outer ring
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: cx-r1, y: cy-r1, width: r1*2, height: r1*2))

        // Center dot
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx-r2, y: cy-r2, width: r2*2, height: r2*2))
    }
}

// MARK: - DetectionRingView
/// 자동 감지된 원을 하이라이트하는 링 뷰 (탭으로 선택 가능)
private class DetectionRingView: UIView {
    var onTap: (() -> Void)?

    init(circle: DetectedCircle, index: Int) {
        let inflated = circle.screenRect.insetBy(dx: -6, dy: -6)
        super.init(frame: inflated)
        backgroundColor = .clear

        let colors: [UIColor] = [
            UIColor(red: 1, green: 0.9, blue: 0, alpha: 1),    // 홀 – 노란색
            UIColor(red: 1, green: 1, blue: 1, alpha: 1),       // 볼 – 흰색
        ]
        let c = colors[min(index, colors.count - 1)]

        layer.borderColor  = c.withAlphaComponent(0.9).cgColor
        layer.borderWidth  = 2.5
        layer.cornerRadius = min(inflated.width, inflated.height) / 2

        // 역할 라벨
        let roleLabel = UILabel()
        roleLabel.text      = circle.role == .hole ? "홀" : circle.role == .ball ? "볼" : "?"
        roleLabel.font      = .systemFont(ofSize: 11, weight: .bold)
        roleLabel.textColor = c
        roleLabel.sizeToFit()
        roleLabel.center    = CGPoint(x: bounds.midX, y: -10)
        addSubview(roleLabel)

        // 탭 제스처
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }
}

// MARK: - LevelIndicatorView
/// 자이로 센서 기반 기기 수평 상태 표시 뷰 (버블 레벨)
class LevelIndicatorView: UIView {

    private(set) var pitchDeg: Double = 0
    private(set) var rollDeg:  Double = 0
    var isLevel: Bool { abs(pitchDeg) < 5.0 && abs(rollDeg) < 5.0 }

    private let bubbleView  = UIView()
    private let reticleView = UIView()
    private let pitchLabel  = UILabel()
    private let rollLabel   = UILabel()
    private let levelBadge  = UILabel()

    private let maxAngle: Double = 15.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        backgroundColor    = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 16
        clipsToBounds      = true

        // 원형 테두리 (버블 영역)
        reticleView.layer.borderWidth  = 1.5
        reticleView.layer.borderColor  = UIColor.white.withAlphaComponent(0.4).cgColor
        reticleView.layer.cornerRadius = 40
        reticleView.backgroundColor    = .clear
        addSubview(reticleView)

        // 십자선
        let hLine = UIView()
        hLine.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        hLine.frame = CGRect(x: 15, y: 51, width: 80, height: 1)
        addSubview(hLine)
        let vLine = UIView()
        vLine.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        vLine.frame = CGRect(x: 55, y: 12, width: 1, height: 80)
        addSubview(vLine)

        // 버블
        bubbleView.layer.cornerRadius = 11
        bubbleView.layer.borderWidth  = 1.5
        bubbleView.layer.borderColor  = UIColor.white.withAlphaComponent(0.5).cgColor
        addSubview(bubbleView)

        // 라벨
        for lbl in [pitchLabel, rollLabel, levelBadge] {
            lbl.font          = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            lbl.textColor     = .white
            lbl.textAlignment = .center
            addSubview(lbl)
        }
        pitchLabel.text    = "앞뒤 0.0°"
        rollLabel.text     = "좌우 0.0°"
        levelBadge.text    = "각도 확인 중"
        levelBadge.font    = .systemFont(ofSize: 10, weight: .bold)
        levelBadge.layer.cornerRadius = 7
        levelBadge.clipsToBounds      = true

        updateBubble()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let arenaSize: CGFloat = 80
        let arenaX = (w - arenaSize) / 2
        reticleView.frame = CGRect(x: arenaX, y: 12, width: arenaSize, height: arenaSize)
        pitchLabel.frame  = CGRect(x: 4, y: 98,  width: w - 8, height: 14)
        rollLabel.frame   = CGRect(x: 4, y: 114, width: w - 8, height: 14)
        levelBadge.frame  = CGRect(x: 6, y: 132, width: w - 12, height: 16)
        updateBubble()
    }

    func update(pitchDeg: Double, rollDeg: Double) {
        self.pitchDeg = pitchDeg
        self.rollDeg  = rollDeg
        updateBubble()
    }

    private func updateBubble() {
        let arena = reticleView.frame
        guard arena.width > 0 else { return }

        let radius: CGFloat  = arena.width / 2
        let bubbleR: CGFloat = 11
        let nx = CGFloat(max(-1, min(1, rollDeg  / maxAngle)))
        let ny = CGFloat(max(-1, min(1, pitchDeg / maxAngle)))

        let cx = arena.midX + nx * (radius - bubbleR)
        let cy = arena.midY + ny * (radius - bubbleR)
        bubbleView.frame = CGRect(x: cx - bubbleR, y: cy - bubbleR,
                                  width: bubbleR * 2, height: bubbleR * 2)

        let maxTilt = max(abs(pitchDeg), abs(rollDeg))
        let color: UIColor
        let badge: String
        if maxTilt < 5.0 {
            color = UIColor(red: 0.2,  green: 0.75, blue: 0.3,  alpha: 1); badge = "✓ 30° 스캔 준비됨"
        } else if maxTilt < 10.0 {
            color = UIColor(red: 1.0,  green: 0.76, blue: 0.03, alpha: 1); badge = "⚠ 30° 맞춰주세요"
        } else {
            color = UIColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1); badge = "✕ 각도 벗어남"
        }
        bubbleView.backgroundColor   = color.withAlphaComponent(0.85)
        bubbleView.layer.borderColor = color.cgColor
        levelBadge.backgroundColor   = color.withAlphaComponent(0.3)
        levelBadge.text              = badge

        // pitchDeg는 목표(60°)로부터의 편차 → 실제 카메라 각도 복원
        let actualAngle = pitchDeg + 30.0
        let pHint: String
        if abs(pitchDeg) < 5      { pHint = "" }
        else if pitchDeg > 0      { pHint = " ↑세워" }
        else                      { pHint = " ↓기울여" }
        let rSign = rollDeg >= 0 ? "→" : "←"
        pitchLabel.text = String(format: "카메라 %.1f°%@", actualAngle, pHint)
        rollLabel.text  = String(format: "좌우%@ %.1f°", rSign, abs(rollDeg))
    }
}

// MARK: - CircleSelectionOverlay
/// 여러 볼 후보 중 사용자가 선택하는 오버레이
class CircleSelectionOverlay: UIView {

    // MARK: - Public API
    /// 선택된 원을 반환
    var onSelect: ((DetectedCircle) -> Void)?
    /// 수동 지정으로 전환 요청
    var onManual: (() -> Void)?

    private let candidates: [DetectedCircle]
    private var ringViews: [SelectableRingView] = []
    private var selectedIndex: Int? {
        didSet { updateSelection() }
    }

    // MARK: - Init
    init(frame: CGRect, candidates: [DetectedCircle]) {
        self.candidates = candidates
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup
    private func setupViews() {
        // 어두운 반투명 배경
        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        // 안내 라벨 (상단)
        let titleBg = UIView()
        titleBg.backgroundColor    = UIColor.black.withAlphaComponent(0.8)
        titleBg.layer.cornerRadius = 16
        titleBg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBg)

        let titleLabel = UILabel()
        titleLabel.text          = "🏐  볼을 선택하세요"
        titleLabel.font          = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor     = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBg.addSubview(titleLabel)

        let subLabel = UILabel()
        subLabel.text          = "볼로 사용할 공을 탭하여 선택한 후 '확정'을 누르세요"
        subLabel.font          = .systemFont(ofSize: 13)
        subLabel.textColor     = UIColor.white.withAlphaComponent(0.75)
        subLabel.textAlignment = .center
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBg.addSubview(subLabel)

        NSLayoutConstraint.activate([
            titleBg.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 60),
            titleBg.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleBg.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9),

            titleLabel.topAnchor.constraint(equalTo: titleBg.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: titleBg.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: titleBg.trailingAnchor, constant: -12),

            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subLabel.leadingAnchor.constraint(equalTo: titleBg.leadingAnchor, constant: 12),
            subLabel.trailingAnchor.constraint(equalTo: titleBg.trailingAnchor, constant: -12),
            subLabel.bottomAnchor.constraint(equalTo: titleBg.bottomAnchor, constant: -12),
        ])

        // 번호가 붙은 탭 가능 링
        for (i, circle) in candidates.enumerated() {
            let ring = SelectableRingView(circle: circle, number: i + 1)
            ring.onTap = { [weak self] in
                self?.selectedIndex = i
            }
            addSubview(ring)
            ringViews.append(ring)
        }

        // 하단 버튼 패널
        setupBottomPanel()
    }

    private func setupBottomPanel() {
        let panel = UIView()
        panel.backgroundColor    = UIColor.black.withAlphaComponent(0.85)
        panel.layer.cornerRadius = 20
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let confirmBtn = UIButton(type: .system)
        confirmBtn.setTitle("✓  이 볼로 확정", for: .normal)
        confirmBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        confirmBtn.setTitleColor(.white, for: .normal)
        confirmBtn.backgroundColor   = UIColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1)
        confirmBtn.layer.cornerRadius = 14
        confirmBtn.translatesAutoresizingMaskIntoConstraints = false
        confirmBtn.addAction(UIAction { [weak self] _ in self?.confirmSelection() }, for: .touchUpInside)

        let manualBtn = UIButton(type: .system)
        manualBtn.setTitle("수동으로 위치 지정", for: .normal)
        manualBtn.titleLabel?.font = .systemFont(ofSize: 14)
        manualBtn.setTitleColor(UIColor.white.withAlphaComponent(0.65), for: .normal)
        manualBtn.translatesAutoresizingMaskIntoConstraints = false
        manualBtn.addAction(UIAction { [weak self] _ in self?.onManual?() }, for: .touchUpInside)

        panel.addSubview(confirmBtn)
        panel.addSubview(manualBtn)

        NSLayoutConstraint.activate([
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.heightAnchor.constraint(equalToConstant: 130),

            confirmBtn.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            confirmBtn.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            confirmBtn.widthAnchor.constraint(equalToConstant: 200),
            confirmBtn.heightAnchor.constraint(equalToConstant: 46),

            manualBtn.topAnchor.constraint(equalTo: confirmBtn.bottomAnchor, constant: 8),
            manualBtn.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
        ])
    }

    // MARK: - Selection
    private func updateSelection() {
        for (i, ring) in ringViews.enumerated() {
            ring.setSelected(i == selectedIndex)
        }
    }

    private func confirmSelection() {
        guard let idx = selectedIndex, idx < candidates.count else {
            // 선택 없이 확정 → 첫 번째 후보 사용
            if !candidates.isEmpty { onSelect?(candidates[0]) }
            return
        }
        onSelect?(candidates[idx])
    }
}

// MARK: - SelectableRingView
/// 번호가 붙은 탭 가능 후보 링 (CircleSelectionOverlay 전용)
class SelectableRingView: UIView {
    var onTap: (() -> Void)?
    private let numberLabel = UILabel()
    private var isSelected = false

    // 선택 상태 색상
    private let normalColor:   UIColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 0.8)
    private let selectedColor: UIColor = UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0)

    init(circle: DetectedCircle, number: Int) {
        // 링이 잘 보이도록 충분한 패딩 적용
        let padded = circle.screenRect.insetBy(dx: -10, dy: -10)
        super.init(frame: padded)
        backgroundColor = .clear

        layer.borderWidth  = 3
        layer.borderColor  = normalColor.cgColor
        layer.cornerRadius = min(padded.width, padded.height) / 2

        // 번호 배지
        numberLabel.text            = "\(number)"
        numberLabel.font            = .systemFont(ofSize: 14, weight: .black)
        numberLabel.textColor       = .black
        numberLabel.textAlignment   = .center
        numberLabel.backgroundColor = normalColor
        numberLabel.layer.cornerRadius = 12
        numberLabel.clipsToBounds   = true
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)

        NSLayoutConstraint.activate([
            numberLabel.widthAnchor.constraint(equalToConstant: 24),
            numberLabel.heightAnchor.constraint(equalToConstant: 24),
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.topAnchor.constraint(equalTo: topAnchor, constant: -12),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        let c = selected ? selectedColor : normalColor
        UIView.animate(withDuration: 0.15) {
            self.layer.borderColor        = c.cgColor
            self.numberLabel.backgroundColor = c
            self.numberLabel.textColor    = selected ? .white : .black
            self.transform = selected ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
        }
    }

    @objc private func tapped() { onTap?() }
}
