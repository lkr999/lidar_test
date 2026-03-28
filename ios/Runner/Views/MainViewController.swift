import UIKit
import ARKit
import SceneKit
import CoreMotion

/// 메인 뷰 컨트롤러 - 실시간 AR 카메라 뷰 + LiDAR 스캔 + 경로 표시
@available(iOS 14.0, *)
class MainViewController: UIViewController {
    
    // MARK: - AR Components
    private var arView: ARSCNView!
    private var scanner: LiDARScanner!
    
    // MARK: - UI Components
    private var overlayView: ScanOverlayView!
    private var trajectoryOverlayView: TrajectoryOverlayView!
    private var statusBar: UIView!
    private var qualityLabel: UILabel!
    private var qualityBar: UIProgressView!
    private var scanButton: UIButton!
    private var measureButton: UIButton!
    private var resetButton: UIButton!
    private var instructionLabel: UILabel!
    
    // MARK: - State
    private var currentState: AppState = .live
    private var currentQuality = MeasurementQuality()
    private var currentHeightMap: HeightMapData?
    private var capturedImage: UIImage?          // RGB 스냅샷
    private var capturedDepthImage: UIImage?     // false-color 깊이 이미지
    private var capturedCompositeImage: UIImage? // RGB + 깊이 합성 이미지
    private var capturedImageView: UIImageView?
    private var isShowingDepth = false           // 뎁스/RGB 뷰 토글 상태
    private var scanProgress: Double = 0         // 현재 스캔 진행률 (0~1)

    // 볼 & 홀 위치 (그리드 좌표)
    private var ballPosition: Vector2?
    private var holePosition: Vector2?
    private var capturedARCamera: ARCamera?

    // 자이로/가속도 수평 측정
    private let motionManager = CMMotionManager()
    private var levelIndicatorView: LevelIndicatorView!

    // 저항값 (0~100%, 기본 50%)
    private var resistancePercent: Double = 50
    private var frictionContainer: UIView!
    private var frictionSlider: UISlider!
    private var frictionLabel: UILabel!

    // 수평 대기 상태 (true: 레벨 OK 시 자동 스캔 시작)
    private var waitingForLevel = false

    // 스캔 정체 감지 (3초 이상 커버리지 변화 없으면 자동 완료)
    private var lastCoverageForStall: Double = -1
    private var lastCoverageChangeTime: Date = Date()
    private var scanStartTime: Date = Date()

    // 스캔 진행률 프로그레스 바
    private var scanInfoContainer: UIView!
    private var scanProgressBar: UIProgressView!
    private var scanProgressLabel: UILabel!

    // 자동 감지 / 위치 조정
    private var detectionTimer: Timer?
    private var detectionSampleCount = 0
    private var accumulatedCircles: [DetectedCircle] = []
    private var adjustOverlay: PositionAdjustOverlay?
    private var pendingBallScreen: CGPoint?
    private var pendingHoleScreen: CGPoint?

    enum AppState {
        case live            // 실시간 카메라
        case scanning        // LiDAR 스캔 중
        case scanned         // 스캔 완료
        case detecting       // 자동 인식 중 (최대 5초)
        case confirmingBall  // 볼 위치 미세조정
        case confirmingHole  // 홀 위치 미세조정
        case measuring       // 경로 계산 중
        case result          // 결과 표시
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        setupScanner()
        setupUI()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scanner.startSession()
        startMotionUpdates()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.pauseSession()
        motionManager.stopDeviceMotionUpdates()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { false }
    
    // MARK: - Setup AR View
    private func setupARView() {
        arView = ARSCNView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.delegate = self
        arView.automaticallyUpdatesLighting = true
        arView.rendersCameraGrain = true
        
        // 메시 시각화
        arView.debugOptions = []
        
        view.addSubview(arView)
    }
    
    // MARK: - Setup Scanner
    private func setupScanner() {
        scanner = LiDARScanner()
        
        // ✅ ARSCNView가 스캐너의 세션을 공유하도록 설정
        // - arView.session(기본): LiDAR 설정 없음 → 카메라 미표시
        // - scanner.arSession: LiDAR 풀설정으로 실행됨
        // → 같은 세션을 사용해야 카메라 화면 + LiDAR 데이터 동시 처리 가능
        arView.session = scanner.arSession
        
        scanner.onQualityUpdate = { [weak self] quality in
            DispatchQueue.main.async {
                self?.updateQualityUI(quality)
                // 스캔 중이면 오버레이 갱신
                if self?.currentState == .scanning {
                    self?.overlayView.update(
                        progress: self?.scanProgress ?? 0,
                        quality:  quality)
                }
            }
        }

        scanner.onScanProgress = { [weak self] progress in
            DispatchQueue.main.async {
                self?.updateScanProgress(progress)
            }
        }
        
        scanner.onScanComplete = { [weak self] heightMap in
            DispatchQueue.main.async {
                self?.onScanCompleted(heightMap)
            }
        }
        
        scanner.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.showError(error)
            }
        }

        // 스캔 중 실시간 깊이 이미지 수신 (~2fps)
        scanner.onDepthImageReady = { [weak self] depthImage in
            guard let self, self.currentState == .scanning else { return }
            self.capturedDepthImage = depthImage
        }

        // LiDAR·자이로 품질이 충분히 달성되면 자동 종료
        scanner.onAutoStopReady = { [weak self] in
            guard let self, self.currentState == .scanning else { return }
            // 오버레이에 완료 배너 표시
            self.overlayView.update(
                progress:      1.0,
                quality:       self.currentQuality,
                autoStopReady: true)
            self.instructionLabel.text = "✅ 품질 달성 – 자동 종료 중..."
            self.stopScanning()
        }
    }
    
    // MARK: - Setup UI
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.05, green: 0.1, blue: 0.16, alpha: 1)

        setupStatusBar()
        setupButtons()
        setupInstructionLabel()
        setupScanOverlay()
        setupTrajectoryOverlay()
        setupLevelIndicator()
        setupFrictionSlider()
        setupScanProgressBar()
    }

    /// 스캔 중 표시되는 품질 시각화 오버레이
    private func setupScanOverlay() {
        overlayView = ScanOverlayView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.isUserInteractionEnabled = false
        overlayView.isHidden = true
        view.insertSubview(overlayView, aboveSubview: arView)
    }
    
    private func setupStatusBar() {
        statusBar = UIView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statusBar.layer.cornerRadius = 16
        statusBar.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        view.addSubview(statusBar)
        
        // 품질 라벨
        qualityLabel = UILabel()
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityLabel.text = "LiDAR 준비 중..."
        qualityLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        qualityLabel.textColor = .white
        statusBar.addSubview(qualityLabel)
        
        // 품질 바
        qualityBar = UIProgressView(progressViewStyle: .default)
        qualityBar.translatesAutoresizingMaskIntoConstraints = false
        qualityBar.progressTintColor = UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 1)
        qualityBar.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        qualityBar.layer.cornerRadius = 3
        qualityBar.clipsToBounds = true
        statusBar.addSubview(qualityBar)
        
        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusBar.heightAnchor.constraint(equalToConstant: 60),
            
            qualityLabel.topAnchor.constraint(equalTo: statusBar.topAnchor, constant: 12),
            qualityLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 16),
            qualityLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -16),
            
            qualityBar.topAnchor.constraint(equalTo: qualityLabel.bottomAnchor, constant: 8),
            qualityBar.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 16),
            qualityBar.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -16),
            qualityBar.heightAnchor.constraint(equalToConstant: 6),
        ])
    }
    
    private func setupButtons() {
        let buttonStack = UIStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 12
        view.addSubview(buttonStack)
        
        // 스캔 버튼
        scanButton = createButton(title: "🔍 스캔 시작", color: UIColor(red: 0.09, green: 0.47, blue: 0.95, alpha: 1))
        scanButton.addTarget(self, action: #selector(scanButtonTapped), for: .touchUpInside)
        buttonStack.addArrangedSubview(scanButton)
        
        // 측정 버튼
        measureButton = createButton(title: "⛳ 측정", color: UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 1))
        measureButton.addTarget(self, action: #selector(measureButtonTapped), for: .touchUpInside)
        measureButton.isEnabled = false
        measureButton.alpha = 0.5
        buttonStack.addArrangedSubview(measureButton)
        
        // 리셋 버튼
        resetButton = createButton(title: "↺ 리셋", color: UIColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 1))
        resetButton.addTarget(self, action: #selector(resetButtonTapped), for: .touchUpInside)
        buttonStack.addArrangedSubview(resetButton)
        
        NSLayoutConstraint.activate([
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 56),
        ])
    }
    
    private func createButton(title: String, color: UIColor) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = color
        btn.layer.cornerRadius = 16
        btn.layer.shadowColor = color.cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 4)
        btn.layer.shadowRadius = 8
        btn.layer.shadowOpacity = 0.4
        return btn
    }
    
    private func setupInstructionLabel() {
        instructionLabel = UILabel()
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.text = "그린 표면을 향해 카메라를 비추세요"
        instructionLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        instructionLabel.layer.cornerRadius = 12
        instructionLabel.clipsToBounds = true
        view.addSubview(instructionLabel)
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -88),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            instructionLabel.heightAnchor.constraint(equalToConstant: 40),
        ])
    }
    
    private func setupTrajectoryOverlay() {
        trajectoryOverlayView = TrajectoryOverlayView(frame: view.bounds)
        trajectoryOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        trajectoryOverlayView.isUserInteractionEnabled = false
        trajectoryOverlayView.isHidden = true
        trajectoryOverlayView.backgroundColor = .clear
        view.addSubview(trajectoryOverlayView)
    }

    private func setupLevelIndicator() {
        levelIndicatorView = LevelIndicatorView()
        levelIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        levelIndicatorView.isHidden = true   // 스캔 시작 시에만 표시
        view.addSubview(levelIndicatorView)
        NSLayoutConstraint.activate([
            levelIndicatorView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            levelIndicatorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 70),
            levelIndicatorView.widthAnchor.constraint(equalToConstant: 110),
            levelIndicatorView.heightAnchor.constraint(equalToConstant: 165),
        ])
    }

    /// 저항값 슬라이더 (0~100%, 기본 50)
    private func setupFrictionSlider() {
        frictionContainer = UIView()
        frictionContainer.translatesAutoresizingMaskIntoConstraints = false
        frictionContainer.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        frictionContainer.layer.cornerRadius = 12
        frictionContainer.isHidden = true
        view.addSubview(frictionContainer)

        frictionLabel = UILabel()
        frictionLabel.translatesAutoresizingMaskIntoConstraints = false
        frictionLabel.text = "저항: 50%"
        frictionLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        frictionLabel.textColor = .white
        frictionLabel.textAlignment = .center
        frictionContainer.addSubview(frictionLabel)

        frictionSlider = UISlider()
        frictionSlider.translatesAutoresizingMaskIntoConstraints = false
        frictionSlider.minimumValue = 0
        frictionSlider.maximumValue = 100
        frictionSlider.value = 50
        frictionSlider.minimumTrackTintColor = UIColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1)
        frictionSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        frictionSlider.addTarget(self, action: #selector(frictionSliderChanged), for: .valueChanged)
        frictionSlider.addTarget(self, action: #selector(frictionSliderFinished), for: [.touchUpInside, .touchUpOutside])
        frictionContainer.addSubview(frictionSlider)

        NSLayoutConstraint.activate([
            frictionContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            frictionContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            frictionContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
            frictionContainer.heightAnchor.constraint(equalToConstant: 56),

            frictionLabel.topAnchor.constraint(equalTo: frictionContainer.topAnchor, constant: 6),
            frictionLabel.leadingAnchor.constraint(equalTo: frictionContainer.leadingAnchor, constant: 12),
            frictionLabel.trailingAnchor.constraint(equalTo: frictionContainer.trailingAnchor, constant: -12),

            frictionSlider.topAnchor.constraint(equalTo: frictionLabel.bottomAnchor, constant: 2),
            frictionSlider.leadingAnchor.constraint(equalTo: frictionContainer.leadingAnchor, constant: 12),
            frictionSlider.trailingAnchor.constraint(equalTo: frictionContainer.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Scan Progress Bar

    private func setupScanProgressBar() {
        scanInfoContainer = UIView()
        scanInfoContainer.translatesAutoresizingMaskIntoConstraints = false
        scanInfoContainer.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        scanInfoContainer.layer.cornerRadius = 10
        scanInfoContainer.isHidden = true
        view.addSubview(scanInfoContainer)

        scanProgressLabel = UILabel()
        scanProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        scanProgressLabel.text = "데이터 수집: 0%"
        scanProgressLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        scanProgressLabel.textColor = .white
        scanInfoContainer.addSubview(scanProgressLabel)

        scanProgressBar = UIProgressView(progressViewStyle: .default)
        scanProgressBar.translatesAutoresizingMaskIntoConstraints = false
        scanProgressBar.progressTintColor = UIColor(red: 0.09, green: 0.47, blue: 0.95, alpha: 1)
        scanProgressBar.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        scanProgressBar.layer.cornerRadius = 4
        scanProgressBar.clipsToBounds = true
        scanProgressBar.setProgress(0, animated: false)
        scanInfoContainer.addSubview(scanProgressBar)

        NSLayoutConstraint.activate([
            scanInfoContainer.topAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: 8),
            scanInfoContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scanInfoContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scanInfoContainer.heightAnchor.constraint(equalToConstant: 40),

            scanProgressLabel.topAnchor.constraint(equalTo: scanInfoContainer.topAnchor, constant: 6),
            scanProgressLabel.leadingAnchor.constraint(equalTo: scanInfoContainer.leadingAnchor, constant: 12),
            scanProgressLabel.trailingAnchor.constraint(equalTo: scanInfoContainer.trailingAnchor, constant: -12),

            scanProgressBar.topAnchor.constraint(equalTo: scanProgressLabel.bottomAnchor, constant: 4),
            scanProgressBar.leadingAnchor.constraint(equalTo: scanInfoContainer.leadingAnchor, constant: 12),
            scanProgressBar.trailingAnchor.constraint(equalTo: scanInfoContainer.trailingAnchor, constant: -12),
            scanProgressBar.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    // MARK: - CoreMotion

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            // 뒷면 카메라 기준 각도 계산
            // 0° = 카메라가 수평(지평선), 90° = 카메라가 수직 아래(바닥)
            // g.z: 기기 Z축(화면 방향) 중력 성분
            //   - 세로로 세운 상태(카메라 수평):  g.z ≈ 0  → cameraAngle ≈ 0°
            //   - 60° 아래를 향할 때:             g.z ≈ -0.866 → cameraAngle ≈ 60°
            //   - 완전히 바닥을 향할 때(face-up): g.z = -1   → cameraAngle = 90°
            let cameraAngle = -asin(max(-1.0, min(1.0, g.z))) * 180.0 / .pi
            // 좌우 기울기 (0° = 수평)
            let rollDeg = asin(max(-1.0, min(1.0, g.x))) * 180.0 / .pi
            // 목표 30°로부터의 편차를 pitchDeg로 전달 (0이면 정확히 30°)
            let pitchDev = cameraAngle - 30.0
            self.levelIndicatorView.update(pitchDeg: pitchDev, rollDeg: rollDeg)

            // 수평 대기 중 → 레벨 OK 되면 자동 스캔 시작
            if self.waitingForLevel && self.levelIndicatorView.isLevel {
                self.waitingForLevel = false
                self.startScanning()
            }
        }
    }
    
    // MARK: - Actions
    @objc private func scanButtonTapped() {
        switch currentState {
        case .live:
            if waitingForLevel {
                // 대기 취소
                waitingForLevel = false
                levelIndicatorView.isHidden = true
                instructionLabel.text = "그린 표면을 향해 카메라를 비추세요"
                scanButton.setTitle("🔍 스캔 시작", for: .normal)
                scanButton.backgroundColor = UIColor(red: 0.09, green: 0.47, blue: 0.95, alpha: 1)
            } else {
                // 수평계 대기 시작 (레벨 OK 되면 자동 스캔)
                waitingForLevel = true
                levelIndicatorView.isHidden = false
                view.bringSubviewToFront(levelIndicatorView)
                view.bringSubviewToFront(statusBar)
                view.bringSubviewToFront(instructionLabel)
                for sv in view.subviews where sv is UIStackView { view.bringSubviewToFront(sv) }
                instructionLabel.text = "카메라를 30° 아래로 향하면 자동 스캔합니다"
                scanButton.setTitle("⏳ 수평 대기 중…", for: .normal)
                scanButton.backgroundColor = UIColor(red: 0.8, green: 0.5, blue: 0.1, alpha: 1)
            }
        case .scanning:
            stopScanning()
        default:
            break
        }
    }
    
    @objc private func measureButtonTapped() {
        switch currentState {
        case .scanned, .result:
            showManualPlacementForBall()
        default:
            break
        }
    }
    
    @objc private func resetButtonTapped() {
        resetToLive()
    }

    @objc private func frictionSliderChanged() {
        let val = Int(frictionSlider.value)
        resistancePercent = Double(val)
        frictionLabel.text = "저항: \(val)%"
    }

    @objc private func frictionSliderFinished() {
        // 결과 화면에서 슬라이더 변경 시 자동 재계산
        if currentState == .result {
            performMeasurement()
        }
    }
    
    // MARK: - State Transitions
    private func startScanning() {
        currentState  = .scanning
        scanProgress  = 0
        waitingForLevel = false
        scanStartTime           = Date()
        lastCoverageForStall    = -1
        lastCoverageChangeTime  = Date()
        scanner.startScan()

        scanButton.setTitle("⏹ 스캔 중지", for: .normal)
        scanButton.backgroundColor = UIColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1)
        instructionLabel.text = "카메라 30° 유지하며 그린 표면을 스캔하세요"

        // 스캔 품질 오버레이 표시 및 애니메이션 시작
        overlayView.update(progress: 0, quality: currentQuality)
        overlayView.isHidden = false
        overlayView.startAnimation()
        view.bringSubviewToFront(overlayView)

        // 수평 인디케이터
        levelIndicatorView.isHidden = false
        view.bringSubviewToFront(levelIndicatorView)

        // 스캔 진행률 바 표시
        scanProgressBar.setProgress(0, animated: false)
        scanProgressLabel.text = "데이터 수집: 0%"
        scanProgressBar.progressTintColor = UIColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1)
        scanInfoContainer.isHidden = false
        view.bringSubviewToFront(scanInfoContainer)

        // 버튼/라벨은 오버레이 위에 유지
        view.bringSubviewToFront(statusBar)
        view.bringSubviewToFront(instructionLabel)
        for sv in view.subviews where sv is UIStackView { view.bringSubviewToFront(sv) }

        arView.debugOptions = [.showWorldOrigin]
    }
    
    private func stopScanning() {
        scanner.stopScan()
        // onScanComplete 콜백에서 처리됨
    }
    
    private func onScanCompleted(_ heightMap: HeightMapData) {
        currentState = .scanned
        currentHeightMap = heightMap

        // 스캔 완료 시점의 카메라 RGB 스냅샷 + 카메라 정보 보존
        // pauseSession은 performMeasurement()에서 호출 (위치 선택 중 raycast 유지)
        capturedImage    = arView.snapshot()
        capturedARCamera = arView.session.currentFrame?.camera

        // ── 깊이 이미지 합성 ──────────────────────────────────────────────
        // 스캔 중 수신한 마지막 깊이 이미지와 RGB를 합성하여 참조 이미지 생성
        if let rgb = capturedImage, let depth = capturedDepthImage {
            capturedCompositeImage = DepthImageRenderer.compositeWithCamera(
                cameraImage: rgb,
                depthImage: depth,
                alpha: 0.45
            )
        } else {
            capturedCompositeImage = capturedImage
        }

        // 스캔 오버레이 & 진행률 바 숨기기
        overlayView.stopAnimation()
        overlayView.isHidden = true
        scanInfoContainer.isHidden = true
        scanProgressBar.setProgress(1.0, animated: false)

        scanButton.setTitle("✅ 스캔 완료", for: .normal)
        scanButton.backgroundColor = UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 1)
        scanButton.isEnabled = false

        measureButton.isEnabled = true
        measureButton.alpha = 1.0

        levelIndicatorView.isHidden = true

        // 분석 결과 → 안내 라벨에 표시
        let heightRange = TerrainAnalyzer.heightRange(terrain: heightMap)
        let stimp       = TerrainAnalyzer.estimateStimpSpeed(terrain: heightMap)

        instructionLabel.text = String(format: "✅ 스캔 완료 | 높이차 %.2fm | Stimp %.1f", heightRange, stimp)

        arView.debugOptions = []

        // 깊이 합성 이미지를 배경으로 표시 (측정 참조 기반 이미지)
        if capturedImageView == nil {
            capturedImageView = UIImageView(frame: view.bounds)
            capturedImageView!.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            capturedImageView!.contentMode = .scaleAspectFill
            view.insertSubview(capturedImageView!, aboveSubview: arView)
        }
        // 위치 선택 중에는 밝은 RGB 이미지 사용 (깊이 합성은 결과 화면에서)
        isShowingDepth = false
        capturedImageView?.image = capturedImage
        capturedImageView?.isHidden = false

        // 저항값 슬라이더 표시
        frictionContainer.isHidden = false
        view.bringSubviewToFront(frictionContainer)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showManualPlacementForBall()
        }
    }
    
    // MARK: - Auto Detection (최대 5초)
    @available(iOS 14.0, *)
    private func startAutoDetection() {
        currentState = .detecting
        accumulatedCircles.removeAll()
        detectionSampleCount = 0
        instructionLabel.text = "🔍 볼·홀 자동 인식 중... (최대 5초)"
        measureButton.isEnabled = false

        // 0.5초마다 샘플링
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.runDetectionSample()
        }
        // 5초 후 강제 종료
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.finalizeDetection()
        }
    }

    @available(iOS 14.0, *)
    private func runDetectionSample() {
        guard currentState == .detecting else { detectionTimer?.invalidate(); return }
        detectionSampleCount += 1
        let snap = arView.snapshot()
        VisionDetector.detectCircles(in: snap, viewSize: arView.bounds.size) { [weak self] circles in
            guard let self, self.currentState == .detecting else { return }
            // 새 원 누적 (중복 제거: 기존과 거리가 먼 것만 추가)
            for c in circles {
                if !self.accumulatedCircles.contains(where: {
                    hypot($0.center.x - c.center.x, $0.center.y - c.center.y) < 40
                }) {
                    self.accumulatedCircles.append(c)
                }
            }
            // 볼·홀 모두 찾으면 즉시 확정
            if self.accumulatedCircles.filter({ $0.role != .unknown }).count >= 2 {
                self.finalizeDetection()
            }
        }
    }

    private func finalizeDetection() {
        guard currentState == .detecting else { return }
        detectionTimer?.invalidate(); detectionTimer = nil

        // 크기 내림차순 정렬
        var circles = accumulatedCircles.sorted { $0.area > $1.area }

        // 역할 부여: 가장 큰 것 = 홀, 나머지 = 볼 후보
        if !circles.isEmpty { circles[0].role = .hole }
        if circles.count > 1 {
            for i in 1..<circles.count { circles[i].role = .ball }
        }

        switch circles.count {
        case 0:
            // 감지 실패 → 수동 모드 바로 진입
            instructionLabel.text = "인식 실패 – 수동으로 볼 위치를 지정하세요"
            showManualPlacementForBall()

        case 1:
            // 1개만 발견 → 종류를 사용자에게 물어봄
            let c = circles[0]
            let alert = UIAlertController(title: "인식된 물체",
                                          message: "감지된 물체를 무엇으로 지정할까요?",
                                          preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "⛳ 홀 (큰 것)", style: .default) { [weak self] _ in
                self?.pendingHoleScreen = c.center
                self?.showManualPlacementForBall()
            })
            alert.addAction(UIAlertAction(title: "🥎 볼 (작은 것)", style: .default) { [weak self] _ in
                self?.pendingBallScreen = c.center
                self?.showManualPlacementForHole()
            })
            alert.addAction(UIAlertAction(title: "수동 지정", style: .cancel) { [weak self] _ in
                self?.showManualPlacementForBall()
            })
            present(alert, animated: true)

        case 2:
            // 정확히 2개 → 자동 배정 (큰 것 = 홀, 작은 것 = 볼)
            pendingHoleScreen = circles[0].center
            pendingBallScreen = circles[1].center
            instructionLabel.text = "✅ 자동 인식 완료! 볼 위치를 확인하세요"
            showBallAdjustOverlay(detectedCircles: circles)

        default:
            // 3개 이상 → 홀 자동 확정(가장 큰 것), 볼은 사용자 선택
            pendingHoleScreen = circles[0].center
            let ballCandidates = Array(circles[1...])
            instructionLabel.text = "볼 여러 개 감지 – 사용할 볼을 선택하세요"
            showBallSelectionOverlay(candidates: ballCandidates, allCircles: circles)
        }
    }

    // MARK: - Ball Selection Overlay (다중 볼 후보)
    private var selectionOverlay: CircleSelectionOverlay?

    private func showBallSelectionOverlay(candidates: [DetectedCircle],
                                          allCircles: [DetectedCircle]) {
        currentState = .confirmingBall
        let overlay = CircleSelectionOverlay(frame: view.bounds, candidates: candidates)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        overlay.onSelect = { [weak self] selected in
            guard let self else { return }
            self.selectionOverlay?.removeFromSuperview()
            self.selectionOverlay = nil
            self.pendingBallScreen = selected.center
            // 볼 위치 미세조정으로 이동
            self.showBallAdjustOverlay(detectedCircles: allCircles)
        }
        overlay.onManual = { [weak self] in
            guard let self else { return }
            self.selectionOverlay?.removeFromSuperview()
            self.selectionOverlay = nil
            self.showManualPlacementForBall()
        }

        view.addSubview(overlay)
        selectionOverlay = overlay
    }

    // MARK: - Manual Placement (fallback)
    private func showManualPlacementForBall() {
        currentState = .scanned
        pendingBallScreen = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY + 100)
        showBallAdjustOverlay(detectedCircles: [])
    }

    private func showManualPlacementForHole() {
        currentState = .scanned
        pendingHoleScreen = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY - 100)
        showHoleAdjustOverlay(detectedCircles: [])
    }

    // MARK: - Position Adjust Overlays
    /// 캡처 이미지가 위치 선택의 배경으로 확실히 보이도록 보장
    private func ensureCapturedImageVisible() {
        guard let imgView = capturedImageView else { return }
        imgView.image = capturedImage
        imgView.isHidden = false
        // arView 바로 위에 위치하도록 보장
        view.insertSubview(imgView, aboveSubview: arView)
    }

    private func showBallAdjustOverlay(detectedCircles: [DetectedCircle]) {
        currentState = .confirmingBall
        ensureCapturedImageVisible()
        let initial = pendingBallScreen ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY + 100)
        let overlay = PositionAdjustOverlay(frame: view.bounds, markerName: "볼", initialPosition: initial)
        overlay.showDetectedCircles(detectedCircles)
        overlay.onConfirm = { [weak self] screenPos in
            self?.removeAdjustOverlay()
            self?.pendingBallScreen = screenPos
            if self?.pendingHoleScreen != nil {
                self?.showHoleAdjustOverlay(detectedCircles: [])
            } else {
                self?.showManualPlacementForHole()
            }
        }
        overlay.onCancel = { [weak self] in
            self?.removeAdjustOverlay()
            self?.resetToLive()
        }
        adjustOverlay = overlay
        view.addSubview(overlay)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        instructionLabel.text = "🏐 볼 위치를 지정 후 확정하세요"
    }

    private func showHoleAdjustOverlay(detectedCircles: [DetectedCircle]) {
        currentState = .confirmingHole
        ensureCapturedImageVisible()
        let initial = pendingHoleScreen ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY - 100)
        let overlay = PositionAdjustOverlay(frame: view.bounds, markerName: "홀", initialPosition: initial)
        overlay.showDetectedCircles(detectedCircles)
        overlay.onConfirm = { [weak self] screenPos in
            self?.removeAdjustOverlay()
            self?.pendingHoleScreen = screenPos
            self?.commitPositionsAndMeasure()
        }
        overlay.onCancel = { [weak self] in
            self?.removeAdjustOverlay()
            self?.resetToLive()
        }
        adjustOverlay = overlay
        view.addSubview(overlay)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        instructionLabel.text = "⛳ 홀 위치를 지정 후 확정하세요"
    }

    private func removeAdjustOverlay() {
        adjustOverlay?.removeFromSuperview()
        adjustOverlay = nil
    }

    /// 확정된 스크린 위치 → 그리드 좌표 변환 후 측정 시작
    private func commitPositionsAndMeasure() {
        guard let ballScreen = pendingBallScreen,
              let holeScreen = pendingHoleScreen else {
            showManualPlacementForBall(); return
        }

        // capturedARCamera가 nil이면 현재 프레임에서 재시도
        if capturedARCamera == nil {
            capturedARCamera = arView.session.currentFrame?.camera
        }

        // 스크린 → 그리드 좌표 변환 (capturedARCamera 역투영)
        if let b = convertScreenToGrid(ballScreen),
           let h = convertScreenToGrid(holeScreen) {
            ballPosition = b
            holePosition = h
        } else {
            // 역투영 실패 시 화면 비율 매핑 (폴백)
            guard let heightMap = currentHeightMap else { return }
            let w = view.bounds.width, he = view.bounds.height
            ballPosition = Vector2(
                x: Double(ballScreen.x / w) * Double(heightMap.gridWidth) * heightMap.cellSize,
                y: Double(ballScreen.y / he) * Double(heightMap.gridHeight) * heightMap.cellSize
            )
            holePosition = Vector2(
                x: Double(holeScreen.x / w) * Double(heightMap.gridWidth) * heightMap.cellSize,
                y: Double(holeScreen.y / he) * Double(heightMap.gridHeight) * heightMap.cellSize
            )
        }
        performMeasurement()
    }

    /// 스크린 좌표 → 그리드 Vector2
    /// camera.projectPoint 역방향 탐색: 그리드 점들을 화면에 투영해 가장 가까운 점을 찾음
    /// → TrajectoryOverlayView의 렌더링과 완전히 일치하여 위치 이동 오류 없음
    private func convertScreenToGrid(_ screenPoint: CGPoint) -> Vector2? {
        guard let camera = capturedARCamera,
              let hm = currentHeightMap else { return nil }

        let viewSize = arView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }

        let ori: UIInterfaceOrientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            .map { $0.interfaceOrientation } ?? .portrait

        let rx = Double(hm.gridWidth)  * hm.cellSize / 2.0
        let rz = Double(hm.gridHeight) * hm.cellSize / 2.0

        // 그리드 인덱스 → 월드 좌표 (TrajectoryOverlayView.gridToWorld3D와 동일 공식)
        func gridIndexToWorld(_ gx: Int, _ gy: Int) -> SIMD3<Float> {
            let gxC = max(0, min(gx, hm.gridWidth  - 1))
            let gyC = max(0, min(gy, hm.gridHeight - 1))
            return SIMD3<Float>(
                Float(Double(gx) * hm.cellSize - rx + hm.originX),
                Float(hm.getHeight(x: gxC, y: gyC)),
                Float(Double(gy) * hm.cellSize - rz + hm.originZ)
            )
        }

        // 월드 좌표 → 화면 좌표 (camera.projectPoint 사용)
        func projectToScreen(_ world: SIMD3<Float>) -> CGPoint? {
            let camSpace = camera.transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1.0)
            guard camSpace.z < 0 else { return nil }
            return camera.projectPoint(world, orientation: ori, viewportSize: viewSize)
        }

        func dist2(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x, dy = a.y - b.y
            return dx * dx + dy * dy
        }

        // 1단계: 거친 탐색 (coarseStep 간격)
        let coarseStep = max(1, min(hm.gridWidth, hm.gridHeight) / 40)
        var bestDist = CGFloat.infinity
        var bestGX = hm.gridWidth / 2
        var bestGY = hm.gridHeight / 2

        var gy = 0
        while gy <= hm.gridHeight {
            var gx = 0
            while gx <= hm.gridWidth {
                let world = gridIndexToWorld(gx, gy)
                if let scr = projectToScreen(world) {
                    let d = dist2(scr, screenPoint)
                    if d < bestDist { bestDist = d; bestGX = gx; bestGY = gy }
                }
                gx += coarseStep
            }
            gy += coarseStep
        }

        // 2단계: 세밀 탐색 (1셀 간격, 주변 ±(coarseStep+1) 범위)
        let searchR = coarseStep + 1
        let gxLo = max(0, bestGX - searchR), gxHi = min(hm.gridWidth,  bestGX + searchR)
        let gyLo = max(0, bestGY - searchR), gyHi = min(hm.gridHeight, bestGY + searchR)
        for gy in gyLo...gyHi {
            for gx in gxLo...gxHi {
                let world = gridIndexToWorld(gx, gy)
                if let scr = projectToScreen(world) {
                    let d = dist2(scr, screenPoint)
                    if d < bestDist { bestDist = d; bestGX = gx; bestGY = gy }
                }
            }
        }

        return Vector2(x: Double(bestGX) * hm.cellSize,
                       y: Double(bestGY) * hm.cellSize)
    }
    
    private func performMeasurement() {
        guard let heightMap = currentHeightMap,
              let ball = ballPosition,
              let hole = holePosition else { return }

        // 위치 확정 후 AR 세션 정지 (raycast가 더 이상 필요 없음)
        scanner.pauseSession()

        currentState = .measuring
        instructionLabel.text = "🔄 최적 경로 계산 중..."
        
        let resistance = resistancePercent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let physics = PuttingPhysics(terrain: heightMap, resistancePercent: resistance)
            let (bestSpeed, result) = physics.findBestSpeedAndPath(ballPos: ball, holePos: hole)
            
            DispatchQueue.main.async {
                self?.showResult(result: result, speed: bestSpeed)
            }
        }
    }
    
    private func showResult(result: SimulationResult, speed: Double) {
        currentState = .result
        
        // AR 뷰 위에 정지된 이미지가 그대로 보이도록 유지
        // 이미 onScanCompleted에서 설정되었으므로 보여주기만 보장

        
        // AR 뷰 위에 정적 이미지 표시
        if capturedImageView == nil {
            capturedImageView = UIImageView(frame: view.bounds)
            capturedImageView!.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            capturedImageView!.contentMode = .scaleAspectFill
            view.insertSubview(capturedImageView!, aboveSubview: arView)
        }
        capturedImageView?.image = capturedImage
        capturedImageView?.isHidden = false
        
        // 경로 오버레이 표시
        trajectoryOverlayView.isHidden = false
        view.bringSubviewToFront(trajectoryOverlayView)
        view.bringSubviewToFront(statusBar)
        view.bringSubviewToFront(instructionLabel)
        // 저항 슬라이더·버튼 위로
        frictionContainer.isHidden = false
        view.bringSubviewToFront(frictionContainer)
        for sv in view.subviews where sv is UIStackView {
            view.bringSubviewToFront(sv)
        }

        let puttDistM = (holePosition! - ballPosition!).length

        if let heightMap = currentHeightMap {
            trajectoryOverlayView.configure(
                terrain: heightMap,
                trajectory: result.trajectory,
                ballPos: ballPosition!,
                holePos: holePosition!,
                aimDirection: result.aimDirection,
                camera: capturedARCamera,
                viewportSize: arView.bounds.size,
                puttDistance: puttDistM,
                breakAmount: result.breakAmount,
                puttSpeed: speed,
                resistancePercent: resistancePercent
            )
        }

        instructionLabel.text = String(format: "거리 %.2fm | Break %.2fm | %.2fm/s | 저항 %.0f%%",
                                       puttDistM, result.breakAmount, speed, resistancePercent)

        measureButton.setTitle("🔄 다시 측정", for: .normal)
    }
    
    private func resetToLive() {
        // 타이머·오버레이·감지 상태 초기화
        detectionTimer?.invalidate()
        detectionTimer = nil
        removeAdjustOverlay()
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
        accumulatedCircles.removeAll()
        pendingBallScreen = nil
        pendingHoleScreen = nil
        waitingForLevel = false

        currentState = .live
        currentHeightMap = nil
        ballPosition = nil
        holePosition = nil
        capturedARCamera = nil
        capturedDepthImage = nil
        capturedCompositeImage = nil
        isShowingDepth = false

        // 정적 이미지 / 오버레이 숨기기
        capturedImageView?.isHidden = true
        trajectoryOverlayView.isHidden = true
        levelIndicatorView.isHidden = true
        frictionContainer.isHidden = true
        overlayView.stopAnimation()
        overlayView.isHidden = true
        scanInfoContainer.isHidden = true
        scanProgressBar.setProgress(0, animated: false)
        scanProgressLabel.text = "데이터 수집: 0%"
        scanProgress = 0

        // 탭 제스처 전부 제거
        arView.gestureRecognizers?.removeAll(where: {
            $0.name == "ballTap" || $0.name == "holeTap"
        })

        // UI 리셋
        scanButton.setTitle("🔍 스캔 시작", for: .normal)
        scanButton.backgroundColor = UIColor(red: 0.09, green: 0.47, blue: 0.95, alpha: 1)
        scanButton.isEnabled = true

        measureButton.setTitle("⛳ 측정", for: .normal)
        measureButton.isEnabled = false
        measureButton.alpha = 0.5

        instructionLabel.text = "그린 표면을 향해 카메라를 비추세요"

        // AR 세션 재시작
        scanner.startSession()
    }
    
    // MARK: - UI Updates
    private func updateQualityUI(_ quality: MeasurementQuality) {
        currentQuality = quality
        qualityLabel.text = quality.statusMessage
        qualityBar.setProgress(Float(quality.overallScore), animated: true)

        let color: UIColor
        if quality.overallScore > 0.7 {
            color = UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 1)
        } else if quality.overallScore > 0.4 {
            color = UIColor(red: 1.0, green: 0.76, blue: 0.03, alpha: 1)
        } else {
            color = UIColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1)
        }
        qualityBar.progressTintColor = color

        // 스캔 중일 때만 커버리지 기반 진행률 바 업데이트
        guard currentState == .scanning else { return }
        let coverage = quality.coveragePercent
        scanProgressBar.setProgress(Float(coverage), animated: true)
        let barColor: UIColor
        if coverage > 0.70 {
            barColor = UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 1)  // 녹색
        } else if coverage > 0.40 {
            barColor = UIColor(red: 1.0, green: 0.76, blue: 0.03, alpha: 1)  // 노란색
        } else {
            barColor = UIColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1) // 빨간색
        }
        scanProgressBar.progressTintColor = barColor
        scanProgressLabel.text = String(format: "데이터 수집: %.0f%%  (신뢰도 %.0f%%)",
            coverage * 100, quality.averageConfidence * 100)

        // ── 3초 정체 감지: 커버리지 변화 없으면 자동 완료 ──────────────
        if abs(coverage - lastCoverageForStall) > 0.002 {
            lastCoverageForStall   = coverage
            lastCoverageChangeTime = Date()
        }
        let stallSeconds  = Date().timeIntervalSince(lastCoverageChangeTime)
        let scanDuration  = Date().timeIntervalSince(scanStartTime)
        if stallSeconds >= 3.0 && coverage > 0.05 && scanDuration >= 3.0 {
            instructionLabel.text = "⏸ 데이터 수집 정체 – 자동 완료"
            stopScanning()
        }
    }
    
    private func updateScanProgress(_ progress: Double) {
        scanProgress = progress
        if currentState == .scanning {
            overlayView.update(progress: progress, quality: currentQuality)
            instructionLabel.text = "카메라 30° 유지하며 그린 표면을 스캔하세요"
        }
        if progress >= 1.0 && currentState == .scanning {
            stopScanning()
        }
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "오류", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - ARSCNViewDelegate
@available(iOS 14.0, *)
extension MainViewController: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard currentState == .scanning,
              let meshAnchor = anchor as? ARMeshAnchor else { return }
        attachMeshNode(to: node, from: meshAnchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        // 스캔 중이 아닐 때는 메시 업데이트 완전 차단 (크래시 방지)
        guard currentState == .scanning,
              let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.childNodes.filter { $0.name == "mesh" }.forEach { $0.removeFromParentNode() }
        attachMeshNode(to: node, from: meshAnchor)
    }

    // MARK: - Mesh Helper
    private func attachMeshNode(to node: SCNNode, from meshAnchor: ARMeshAnchor) {
        let meshGeometry = meshAnchor.geometry
        let vertices = meshGeometry.vertices
        let faces    = meshGeometry.faces

        guard vertices.count > 0, faces.count > 0 else { return }

        // ── 버텍스 수집 ─────────────────────────────────────────────────────
        var scnVertices: [SCNVector3] = []
        scnVertices.reserveCapacity(vertices.count)
        let vertexBuffer = vertices.buffer.contents()

        for i in 0..<vertices.count {
            let ptr    = vertexBuffer.advanced(by: i * vertices.stride)
            let vertex = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            scnVertices.append(SCNVector3(vertex.x, vertex.y, vertex.z))
        }

        let vertexSource = SCNGeometrySource(vertices: scnVertices)

        // ── 인덱스 수집 ─────────────────────────────────────────────────────
        // ARKit 메시는 bytesPerIndex 가 2(UInt16) 또는 4(UInt32) 모두 가능.
        // 기존 코드는 항상 UInt32로 읽어 UInt16 메시에서 크래시 발생 → 분기 처리.
        let faceBuffer = faces.buffer.contents()
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * faces.indexCountPerPrimitive)

        for i in 0..<faces.count {
            let faceOff = i * faces.indexCountPerPrimitive * faces.bytesPerIndex
            for j in 0..<faces.indexCountPerPrimitive {
                let idxPtr = faceBuffer.advanced(by: faceOff + j * faces.bytesPerIndex)
                let index: UInt32
                if faces.bytesPerIndex == 2 {
                    index = UInt32(idxPtr.assumingMemoryBound(to: UInt16.self).pointee)
                } else {
                    index = idxPtr.assumingMemoryBound(to: UInt32.self).pointee
                }
                indices.append(index)
            }
        }

        guard !indices.isEmpty else { return }

        let element  = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 0.3)
        material.isDoubleSided    = true
        material.fillMode         = .lines
        geometry.materials        = [material]

        let meshNode = SCNNode(geometry: geometry)
        meshNode.name = "mesh"
        node.addChildNode(meshNode)
    }
}
