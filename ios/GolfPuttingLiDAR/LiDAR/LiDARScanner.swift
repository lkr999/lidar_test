import Foundation
import ARKit
import CoreVideo
import Accelerate
import CoreMotion

/// LiDAR 스캐너 - ARKit SceneDepth를 이용한 실제 LiDAR 데이터 수집
///
/// 주요 개선사항 (v3.0):
/// - 깊이 맵 **모든 픽셀** 처리 (step=1, 최대 정밀도)
/// - 유효 거리 **10m** 확장, 거리 기반 신뢰도 감쇠(distance decay)
/// - **자이로/중력 벡터** 기반 카메라 기울기 품질 가중치 적용
/// - **지면 평면 감지**로 Y=0 기준면 보정 + 카메라 높이 추적
/// - **바로미터(고도계)** 기반 카메라 높이 추정 강화
/// - **그리드 원점 패닝** — 스캔 중 카메라 이동 시 그리드 자동 추적
/// - Accelerate/vDSP 가속 필터링 + vImage 활용 미디언 필터
/// - 프레임마다 false-color **깊이 이미지** 생성 → `onDepthImageReady` 콜백
/// - **실시간 스트리밍** 메쉬 업데이트 콜백 (스캔 중 0.5초 간격)
/// - **ARKit World Map** 저장/복원 (재방문 시 기존 맵 재사용)
/// - **통계적 이상치 제거** 사전 필터링
/// - 스캔 완료 시 tiltPitch/tiltRoll/totalPointCount 를 HeightMapData에 기록
@available(iOS 14.0, *)
class LiDARScanner: NSObject, ARSessionDelegate {

    // MARK: - Properties

    private let session: ARSession
    private let processingQueue = DispatchQueue(label: "lidar.processing.queue", qos: .userInitiated)
    private var isScanning = false

    // 높이 맵 그리드 설정 + 누적 버퍼 (폭 3m × 깊이 10m, 5cm 해상도)
    // 그리드는 스캔 시작 시 카메라가 바라보는 방향(yaw)에 정렬된다:
    // 로컬 X = 폭(3m), 로컬 Z = 깊이(카메라 전방 10m)
    // 누적/평균화 순수 로직은 TerrainGridAccumulator로 분리 (단위 테스트 가능)
    private var grid = TerrainGridAccumulator(
        gridWidth: 60, gridHeight: 200, cellSize: 0.05,
        targetSamplesPerCell: 2
    )
    private var targetGridWidth:  Int    { grid.gridWidth }
    private var targetGridHeight: Int    { grid.gridHeight }
    private var targetCellSize:   Double { grid.cellSize }
    // 스캔 ROI: 오버레이 가이드와 동일 — 화면 전체 (ScanOverlayView.draw 참조)
    private let scanRectWidthRatio: Double = 1.0
    private let scanRectHeightRatio: Double = 1.0
    /// 가이드 사각형의 화면 세로 중심 오프셋 (pt, ScanOverlayView와 동일)
    private let scanRectCenterYOffset: Double = 0.0

    // ── ROI 매핑용 뷰포트 정보 (메인 뷰에서 설정) ─────────────────────────
    /// AR 화면 뷰포트 크기. 화면 가이드 사각형을 깊이 맵 좌표로 역변환할 때 사용.
    var viewportSize: CGSize = .zero
    var viewportOrientation: UIInterfaceOrientation = .portrait

    // 포즈 / 조명 이력
    private var recentPoses:          [simd_float4x4] = []
    private var recentLightEstimates: [Double]         = []
    private var frameCount = 0
    private let minFramesForReliableScan = 12
    private let minReliableScanDuration: TimeInterval = 0.45
    private let maxScanToResultDuration: TimeInterval = 5.0
    private let finalProcessingReserve: TimeInterval = 1.2
    private var maxDataCollectionDuration: TimeInterval {
        max(0.5, maxScanToResultDuration - finalProcessingReserve)
    }
    private var scanStartTimestamp: TimeInterval = 0
    private var scanDeadlineToken: TimeInterval?
    private var normalScanElapsed: TimeInterval = 0
    private var normalScanStartTimestamp: TimeInterval?
    private var normalScanFrameCount = 0

    // 메시 데이터
    private var meshVertices: [SIMD3<Float>] = []

    // ── 자이로·기울기 추적 ──────────────────────────────────────────────────
    private var cumulativeTiltPitch: Double = 0
    private var cumulativeTiltRoll:  Double = 0
    private var tiltSampleCount: Int = 0
    private var totalContributedPoints: Int = 0
    private var lastDepthImageTime: TimeInterval = 0
    private(set) var currentTiltPitch: Double = 0
    private(set) var currentTiltRoll:  Double = 0

    // ── 지면 평면 + 카메라 높이 추적 ──────────────────────────────
    private var detectedGroundY: Float = 0
    private var groundDetected = false
    private(set) var estimatedCameraHeight: Float = 1.6

    // ── 바로미터(고도계) 기반 카메라 높이 추정 강화 ──────────────────
    private let altimeter = CMAltimeter()
    /// 바로미터 기준 고도 (스캔 시작 시점)
    private var barometerBaseAltitude: Double?
    /// 바로미터 상대 고도 변화 (기준 대비, m)
    private var barometerRelativeAlt: Double = 0
    /// 바로미터 + ARKit 복합 카메라 높이
    private var fusedCameraHeight: Float = 1.6

    // ── 그리드 동적 원점 (카메라 위치 기반) + 패닝 ──────────────────
    private var gridOriginX: Double = 0
    private var gridOriginZ: Double = 0
    private var gridOriginSet = false
    /// 그리드 yaw — 스캔 시작 시 카메라 방향. 월드↔그리드 로컬 변환에 사용
    private var gridYaw: Double = 0
    private var gridYawCos: Double = 1
    private var gridYawSin: Double = 0
    /// 마지막 패닝 체크 시 카메라 위치
    private var lastPanCameraX: Double = 0
    private var lastPanCameraZ: Double = 0
    /// 그리드 패닝 임계 거리 (카메라가 그리드 중심에서 이 거리 이상 이동 시 패닝)
    /// 8m 그리드(half-range 4m)의 ~37% 수준으로 설정해 가장자리 데이터 손실 방지
    private let gridPanThreshold: Double = 1.5

    // ── 자동 종료 추적 ────────────────────────────────────────────────────
    private var autoQualityFrames = 0
    private let autoQualityRequired = 1
    private var autoStopSignaled = false
    private var latestQuality = MeasurementQuality()

    // ── 실시간 스트리밍 메쉬 ────────────────────────────────────────────
    private var lastStreamingTime: TimeInterval = 0
    /// 스트리밍 간격 (초)
    private let streamingInterval: TimeInterval = 0.5

    // MARK: - Callbacks

    var onQualityUpdate:   ((MeasurementQuality) -> Void)?
    var onScanComplete:    ((HeightMapData) -> Void)?
    var onFrameUpdate:     ((ARFrame) -> Void)?
    var onScanProgress:    ((Double) -> Void)?
    var onError:           ((String) -> Void)?
    var onDepthImageReady: ((UIImage) -> Void)?
    var onAutoStopReady:   (() -> Void)?
    /// 실시간 스트리밍 메쉬 업데이트 (스캔 중 0.5초 간격)
    var onStreamingMeshUpdate: ((HeightMapData) -> Void)?

    // MARK: - Init

    override init() {
        self.session = ARSession()
        super.init()
        session.delegate = self
        session.delegateQueue = processingQueue
    }

    var arSession: ARSession { session }

    // MARK: - LiDAR Support Check

    static var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    // MARK: - Session Management

    func startSession() {
        guard LiDARScanner.isLiDARSupported else {
            onError?("이 기기는 LiDAR를 지원하지 않습니다.")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        config.environmentTexturing  = .none
        config.isAutoFocusEnabled    = true
        config.planeDetection        = [.horizontal]

        session.run(config, options: [.removeExistingAnchors, .resetTracking])

        // 바로미터 시작
        startBarometer()
    }

    func pauseSession() {
        session.pause()
        stopBarometer()
    }

    // MARK: - Barometer (고도계) — 카메라 높이 추정 강화

    private func startBarometer() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        barometerBaseAltitude = nil
        barometerRelativeAlt = 0

        altimeter.startRelativeAltitudeUpdates(to: OperationQueue.main) { [weak self] data, _ in
            guard let self, let data else { return }
            let altitude = data.relativeAltitude.doubleValue
            if self.barometerBaseAltitude == nil {
                self.barometerBaseAltitude = altitude
            }
            self.barometerRelativeAlt = altitude - (self.barometerBaseAltitude ?? 0)

            // 바로미터 + ARKit 융합: ARKit이 주, 바로미터로 보정
            if self.groundDetected {
                let arkitHeight = self.estimatedCameraHeight
                let baroCorrection = Float(self.barometerRelativeAlt)
                // 바로미터 변화량을 ARKit 높이에 보정으로 적용 (0.3 가중)
                self.fusedCameraHeight = arkitHeight + baroCorrection * 0.3
            }
        }
    }

    private func stopBarometer() {
        altimeter.stopRelativeAltitudeUpdates()
    }

    // MARK: - World Map 저장/복원

    /// 현재 ARKit World Map을 Data로 저장 (재방문 시 재사용)
    func saveWorldMap(completion: @escaping (Data?) -> Void) {
        session.getCurrentWorldMap { worldMap, error in
            guard let worldMap else {
                completion(nil)
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: worldMap,
                    requiringSecureCoding: true
                )
                completion(data)
            } catch {
                completion(nil)
            }
        }
    }

    /// 저장된 World Map으로 세션 복원 (기존 맵 재사용)
    func loadWorldMap(from data: Data) {
        guard let worldMap = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARWorldMap.self, from: data
        ) else { return }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.environmentTexturing = .none
        config.isAutoFocusEnabled   = true
        config.planeDetection       = [.horizontal]
        config.initialWorldMap      = worldMap

        session.run(config, options: [.removeExistingAnchors])
    }

    // MARK: - Scan Control

    func startScan() {
        let startedAt = Date().timeIntervalSince1970
        // 누적 버퍼는 ARSessionDelegate와 같은 processingQueue에서만 변경 (데이터 레이스 방지)
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.resetAccumulators()
            self.isScanning = true
            self.frameCount = 0
            self.scanStartTimestamp = startedAt
            self.scanDeadlineToken = startedAt
            // 바로미터 기준 재설정
            self.barometerBaseAltitude = nil
            self.barometerRelativeAlt = 0
        }
        scheduleScanStartHardStop(startedAt: startedAt)
    }

    func stopScan() {
        processingQueue.async { [weak self] in
            self?.finishScanIfNeeded()
        }
    }

    private func finishScanIfNeeded(expectedToken: TimeInterval? = nil) {
        if let expectedToken, scanDeadlineToken != expectedToken { return }
        guard isScanning else { return }
        isScanning = false
        scanDeadlineToken = nil
        processFinalHeightMap()
    }

    private func resetAccumulators() {
        grid.reset()
        meshVertices.removeAll()
        recentPoses.removeAll()
        recentLightEstimates.removeAll()
        cumulativeTiltPitch    = 0
        cumulativeTiltRoll     = 0
        tiltSampleCount        = 0
        totalContributedPoints = 0
        scanStartTimestamp     = 0
        scanDeadlineToken      = nil
        normalScanElapsed       = 0
        normalScanStartTimestamp = nil
        normalScanFrameCount    = 0
        autoQualityFrames      = 0
        autoStopSignaled       = false
        gridOriginX            = 0
        gridOriginZ            = 0
        gridOriginSet          = false
        gridYaw                = 0
        gridYawCos             = 1
        gridYawSin             = 0
        lastPanCameraX         = 0
        lastPanCameraZ         = 0
        groundDetected         = false
        detectedGroundY        = 0
        estimatedCameraHeight  = 1.6
        fusedCameraHeight      = 1.6
        lastStreamingTime      = 0
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrameUpdate?(frame)

        guard isScanning else {
            updateQuality(frame: frame)
            return
        }

        frameCount += 1
        guard !autoStopSignaled else { return }

        // 포즈 이력 유지
        recentPoses.append(frame.camera.transform)
        if recentPoses.count > 30 { recentPoses.removeFirst() }

        // 조명 이력 유지
        if let le = frame.lightEstimate {
            recentLightEstimates.append(le.ambientIntensity)
            if recentLightEstimates.count > 30 { recentLightEstimates.removeFirst() }
        }

        // ── 자이로 기울기 추출 ────────────────────────────────────────────
        let cam  = frame.camera.transform
        let fwdY = -cam.columns.2.y
        let pointingDownScore = Double(max(-1, min(1, fwdY)))

        let euler = frame.camera.eulerAngles
        let pitchDeg = Double(euler.x) * 180.0 / .pi
        let rollDeg  = Double(euler.z) * 180.0 / .pi
        currentTiltPitch = pitchDeg
        currentTiltRoll  = rollDeg

        guard pointingDownScore > 0.15 else {
            updateQuality(frame: frame)
            updateNormalScanTimer(
                now: Date().timeIntervalSince1970,
                frame: frame,
                pointingDownScore: pointingDownScore
            )
            checkAutoStop()
            return
        }

        // 기울기 평균은 데이터 수집에 실제 사용된(기울기 정상) 프레임만 반영
        cumulativeTiltPitch += pitchDeg
        cumulativeTiltRoll  += rollDeg
        tiltSampleCount     += 1

        // 카메라 높이 갱신 (지면 감지 + 바로미터 융합)
        let camPosY = frame.camera.transform.columns.3.y
        if groundDetected {
            estimatedCameraHeight = camPosY - detectedGroundY
            // 바로미터 융합 높이 갱신
            fusedCameraHeight = estimatedCameraHeight + Float(barometerRelativeAlt) * 0.3
        }

        // ── 그리드 원점 설정 또는 패닝 ────────────────────────────────────
        let camPosX = Double(frame.camera.transform.columns.3.x)
        let camPosZ = Double(frame.camera.transform.columns.3.z)

        if !gridOriginSet {
            // 첫 유효 프레임: 카메라가 바라보는 방향에 그리드를 정렬하고,
            // 전방 5m(깊이 10m의 절반) 지점을 그리드 중심으로 설정
            let camFwd = frame.camera.transform.columns.2
            let fwdX = -Double(camFwd.x)
            let fwdZ = -Double(camFwd.z)
            let fwdLen = sqrt(fwdX * fwdX + fwdZ * fwdZ)
            let halfDepth = Double(targetGridHeight) * targetCellSize / 2.0
            if fwdLen > 0.01 {
                let fx = fwdX / fwdLen, fz = fwdZ / fwdLen
                gridOriginX = camPosX + fx * halfDepth
                gridOriginZ = camPosZ + fz * halfDepth
                // 그리드 로컬 +Z(깊이) 축이 카메라 전방을 향하도록 yaw 설정
                gridYaw = atan2(-fx, fz)
            } else {
                gridOriginX = camPosX
                gridOriginZ = camPosZ
                gridYaw = 0
            }
            gridYawCos = cos(gridYaw)
            gridYawSin = sin(gridYaw)
            gridOriginSet = true
            lastPanCameraX = camPosX
            lastPanCameraZ = camPosZ
        } else {
            // 스캔 중 카메라 이동 시 그리드 원점 패닝
            updateGridOriginIfNeeded(cameraX: camPosX, cameraZ: camPosZ)
        }

        // 깊이 처리
        processDepthData(frame: frame, tiltQuality: pointingDownScore)
        updateQuality(frame: frame)
        updateNormalScanTimer(
            now: Date().timeIntervalSince1970,
            frame: frame,
            pointingDownScore: pointingDownScore
        )

        // 진행률 업데이트: 정상 품질 스캔 누적 시간·프레임·커버리지를 함께 반영
        let timeProgress = min(1.0, elapsedSinceScanStart() / maxDataCollectionDuration)
        let frameProgress = min(1.0, Double(normalScanFrameCount) / Double(minFramesForReliableScan))
        let coverageProgress = min(1.0, Double(grid.filledCellCount) / Double(targetCoverageCellCount()))
        let progress = min(1.0, max(timeProgress, min(frameProgress, coverageProgress)))
        onScanProgress?(progress)

        // 실시간 깊이 이미지 (약 2fps)
        emitDepthImageThrottled(frame: frame, pitchDeg: pitchDeg, rollDeg: rollDeg)

        // 실시간 스트리밍 메쉬 업데이트 (0.5초 간격)
        emitStreamingMeshIfNeeded()

        checkAutoStop()
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                let planeY = plane.transform.columns.3.y
                if !groundDetected || planeY < detectedGroundY {
                    detectedGroundY = planeY
                    groundDetected = true
                }
            }
            guard isScanning else { continue }
            if let mesh = anchor as? ARMeshAnchor { extractMeshVertices(mesh) }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                let planeY = plane.transform.columns.3.y
                if planeY < detectedGroundY || !groundDetected {
                    detectedGroundY = planeY
                    groundDetected = true
                }
            }
            guard isScanning else { continue }
            if let mesh = anchor as? ARMeshAnchor { extractMeshVertices(mesh) }
        }
    }

    // MARK: - Grid Origin Panning (스캔 중 카메라 이동 추적)

    /// 카메라가 그리드 설정 시점(또는 마지막 패닝 시점)에서 임계 거리 이상
    /// 이동하면 그리드를 같은 양만큼 시프트해 전방 배치를 유지한다.
    /// 주의: 그리드 원점은 카메라 전방 4m에 있으므로 원점과의 절대 거리가 아니라
    /// 카메라 이동량(delta) 기준으로 판단해야 한다.
    private func updateGridOriginIfNeeded(cameraX: Double, cameraZ: Double) {
        let dx = cameraX - lastPanCameraX
        let dz = cameraZ - lastPanCameraZ

        // 이동량을 그리드 로컬 축(yaw 역회전)으로 변환해 판단·시프트
        let localDX =  dx * gridYawCos + dz * gridYawSin
        let localDZ = -dx * gridYawSin + dz * gridYawCos

        guard abs(localDX) > gridPanThreshold || abs(localDZ) > gridPanThreshold else { return }

        // 시프트할 셀 수 계산
        let shiftCellsX = Int((localDX / targetCellSize).rounded())
        let shiftCellsZ = Int((localDZ / targetCellSize).rounded())

        guard shiftCellsX != 0 || shiftCellsZ != 0 else { return }

        // 그리드 데이터 시프트
        grid.shift(dxCells: shiftCellsX, dzCells: shiftCellsZ)

        // 셀 단위로 양자화된 로컬 이동량을 월드 좌표로 환산해 원점·기준 갱신
        let movedLX = Double(shiftCellsX) * targetCellSize
        let movedLZ = Double(shiftCellsZ) * targetCellSize
        let movedWX = movedLX * gridYawCos - movedLZ * gridYawSin
        let movedWZ = movedLX * gridYawSin + movedLZ * gridYawCos
        gridOriginX += movedWX
        gridOriginZ += movedWZ
        lastPanCameraX += movedWX
        lastPanCameraZ += movedWZ
    }

    // MARK: - Depth Processing

    /// LiDAR 깊이 맵 **모든 픽셀**을 처리하여 높이 그리드에 축적
    private func processDepthData(frame: ARFrame, tiltQuality: Double) {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let depthMap       = depthData.depthMap
        guard let confMap  = depthData.confidenceMap else { return }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confMap,  .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confMap,  .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase  = CVPixelBufferGetBaseAddress(confMap) else { return }

        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confPtr  = confBase.assumingMemoryBound(to: UInt8.self)

        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let confStride  = CVPixelBufferGetBytesPerRow(confMap)

        let intrinsics       = frame.camera.intrinsics
        let cameraTransform  = frame.camera.transform
        let imageResolution = frame.camera.imageResolution
        let scaleX = imageResolution.width > 0 ? Float(dw) / Float(imageResolution.width) : 1.0
        let scaleY = imageResolution.height > 0 ? Float(dh) / Float(imageResolution.height) : 1.0
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY

        let step = adaptiveDepthStep()
        var localPoints = 0
        // 화면 가이드 사각형을 깊이 맵 정규 좌표로 변환
        // (깊이 맵은 landscape 방향이므로 화면 비율을 직접 쓰면 90° 어긋난다)
        let roi = depthROI(frame: frame)
        let roiMinU = roi.minU, roiMaxU = roi.maxU
        let roiMinV = roi.minV, roiMaxV = roi.maxV

        // 카메라 높이에 따른 유효 최대 거리 동적 계산 (바로미터 융합 높이 사용)
        let effectiveHeight = max(estimatedCameraHeight, fusedCameraHeight)
        let dynamicMaxDepth: Float = min(10.0, effectiveHeight / 0.15 + 2.0)

        for v in stride(from: 0, to: dh, by: step) {
            for u in stride(from: 0, to: dw, by: step) {
                let nu = Double(u) / Double(dw)
                let nv = Double(v) / Double(dh)
                guard nu >= roiMinU, nu <= roiMaxU, nv >= roiMinV, nv <= roiMaxV else { continue }

                let depth      = depthPtr[v * depthStride + u]
                let confidence = confPtr[v * confStride + u]

                // 유효 거리 범위 0.1~10m (카메라 높이에 따라 동적 상한)
                guard depth > 0.1, depth < dynamicMaxDepth else { continue }

                let confLevelBase: Double = confidence == 2 ? 1.0 : confidence == 1 ? 0.6 : 0.3

                // 거리 기반 신뢰도 감쇠 (3m 이내=1.0, 이후 선형 감소, 10m=0.3)
                let distDecay: Double = depth <= 3.0 ? 1.0 : max(0.3, 1.0 - Double(depth - 3.0) / 10.0)

                // 복합 가중치: 신뢰도 × 기울기 × 거리감쇠
                let confWeight = confLevelBase * tiltQuality * distDecay

                // 카메라 좌표 → 월드 좌표 변환
                let z  = depth
                let xc = (Float(u) - cx) * z / fx
                let yc = (Float(v) - cy) * z / fy

                let localPt  = SIMD4<Float>(xc, yc, -z, 1.0)
                let worldPt  = cameraTransform * localPt

                // 수용 정책은 센서 자체 신뢰도(high=2)로 판단한다.
                // 복합 가중치는 권장 각도 30°에서도 기울기 항(~0.5) 때문에 0.75 미만이
                // 되어, 가중치 기준으로는 셀당 2개 이후 모든 깊이 샘플이 거부되고
                // 그리드가 비어 평면으로 잘못 인식될 수 있다.
                if mapToGrid(worldX: Double(worldPt.x),
                             worldY: Double(worldPt.y),
                             worldZ: Double(worldPt.z),
                             confidence: confWeight,
                             isHighConfidence: confidence == 2) {
                    localPoints += 1
                }
            }
        }

        totalContributedPoints += localPoints
    }

    private func adaptiveDepthStep() -> Int {
        return 1
    }

    /// 화면 가이드 사각형(ScanOverlayView와 동일 형상)을 깊이 맵 정규 좌표 ROI로 변환.
    /// `displayTransform` 역변환으로 화면 회전(portrait↔landscape)과
    /// aspect-fill 크롭을 정확히 반영한다.
    private func depthROI(frame: ARFrame)
        -> (minU: Double, maxU: Double, minV: Double, maxV: Double)
    {
        // 뷰포트 미설정 시 보수적 폴백: 깊이 맵 중앙 영역 전체 사용
        guard viewportSize.width > 1, viewportSize.height > 1 else {
            return (0.05, 0.95, 0.05, 0.95)
        }

        // 가이드 사각형 (정규화된 뷰 좌표, ScanOverlayView.draw와 동일 형상)
        let centerY = 0.5 + scanRectCenterYOffset / Double(viewportSize.height)
        let viewRect = CGRect(
            x: (1.0 - scanRectWidthRatio) / 2.0,
            y: centerY - scanRectHeightRatio / 2.0,
            width: scanRectWidthRatio,
            height: scanRectHeightRatio
        )

        // 정규화된 뷰 좌표 → 정규화된 이미지(깊이 맵) 좌표
        let toImage = frame.displayTransform(
            for: viewportOrientation,
            viewportSize: viewportSize
        ).inverted()
        let imageRect = viewRect.applying(toImage)

        let minU = max(0.0, Double(imageRect.minX))
        let maxU = min(1.0, Double(imageRect.maxX))
        let minV = max(0.0, Double(imageRect.minY))
        let maxV = min(1.0, Double(imageRect.maxY))

        // 변환 결과가 비정상(너무 좁거나 뒤집힘)이면 중앙 영역 폴백.
        // ROI가 0이 되면 그리드가 비어 지형이 평면으로 잘못 인식된다.
        guard maxU - minU > 0.10, maxV - minV > 0.10 else {
            return (0.05, 0.95, 0.05, 0.95)
        }
        return (minU, maxU, minV, maxV)
    }

    // MARK: - Mesh Processing

    private func extractMeshVertices(_ meshAnchor: ARMeshAnchor) {
        let geo     = meshAnchor.geometry
        let verts   = geo.vertices
        let vBuf    = verts.buffer.contents()
        let vStride = verts.stride
        let tfm     = meshAnchor.transform
        // 지면 ±0.5m 밴드 밖 정점(벽·다리·사물)은 높이 평균을 왜곡하므로 제외
        let groundBand: Float = 0.5

        // face classification이 있으면 .floor로 분류된 면의 정점만 사용 (가장 정확)
        if let classification = geo.classification {
            let faces         = geo.faces
            let fBuf          = faces.buffer.contents()
            let cBuf          = classification.buffer.contents()
            let cStride       = classification.stride
            let cOffset       = classification.offset
            let idxPerFace    = faces.indexCountPerPrimitive
            let bytesPerIndex = faces.bytesPerIndex
            // 정점은 여러 면에 공유되므로 중복 기여를 막기 위해 인덱스를 모은다
            var floorVertexIndices = Set<Int>()

            for faceIdx in 0 ..< faces.count {
                let clsValue = cBuf
                    .advanced(by: faceIdx * cStride + cOffset)
                    .assumingMemoryBound(to: UInt8.self).pointee
                let cls = ARMeshClassification(rawValue: Int(clsValue)) ?? .none
                // .floor 면은 항상 수용. 야외 잔디·그린은 .none으로 분류되는 경우가
                // 많으므로, 지면 평면이 감지된 경우에 한해 .none 면도 수용한다
                // (contributeMeshVertex의 지면 밴드 필터가 벽·사물을 걸러낸다).
                let acceptable = cls == .floor || (cls == .none && groundDetected)
                guard acceptable else { continue }

                for corner in 0 ..< idxPerFace {
                    let byteOffset = (faceIdx * idxPerFace + corner) * bytesPerIndex
                    let vertIdx: Int
                    if bytesPerIndex == 2 {
                        vertIdx = Int(fBuf.advanced(by: byteOffset)
                            .assumingMemoryBound(to: UInt16.self).pointee)
                    } else {
                        vertIdx = Int(fBuf.advanced(by: byteOffset)
                            .assumingMemoryBound(to: UInt32.self).pointee)
                    }
                    floorVertexIndices.insert(vertIdx)
                }
            }

            for vertIdx in floorVertexIndices {
                contributeMeshVertex(index: vertIdx, buffer: vBuf, vertexStride: vStride,
                                     transform: tfm, groundBand: groundBand)
            }
            return
        }

        // classification 미지원 폴백: 지면 평면 감지 후 지면 밴드 내 정점만 사용
        guard groundDetected else { return }
        for i in 0 ..< verts.count {
            contributeMeshVertex(index: i, buffer: vBuf, vertexStride: vStride,
                                 transform: tfm, groundBand: groundBand)
        }
    }

    private func contributeMeshVertex(index: Int, buffer: UnsafeMutableRawPointer,
                                      vertexStride: Int, transform: simd_float4x4,
                                      groundBand: Float) {
        let v = buffer.advanced(by: index * vertexStride)
            .assumingMemoryBound(to: SIMD3<Float>.self).pointee
        let world = transform * SIMD4<Float>(v, 1.0)
        // 지면이 감지된 경우 지면 밴드 밖 정점 제외 (classification 보조 필터)
        if groundDetected && abs(world.y - detectedGroundY) >= groundBand { return }
        // 깊이 데이터보다 낮은 신뢰도로 기여 (저신뢰 상한 정책에 따라 자동 제한)
        mapToGrid(worldX: Double(world.x),
                  worldY: Double(world.y),
                  worldZ: Double(world.z),
                  confidence: 0.3)
    }

    // MARK: - Grid Mapping

    /// 월드 좌표 샘플을 그리드 상대 좌표로 변환해 누적기로 위임.
    /// 샘플 수용 정책(고신뢰 무제한·저신뢰 상한)은 TerrainGridAccumulator 참조.
    @discardableResult
    private func mapToGrid(worldX: Double, worldY: Double, worldZ: Double,
                           confidence: Double, isHighConfidence: Bool = false) -> Bool {
        // 월드 → 그리드 로컬 (yaw 역회전): 그리드는 스캔 시작 카메라 방향에 정렬됨
        let dx = worldX - gridOriginX
        let dz = worldZ - gridOriginZ
        let relX =  dx * gridYawCos + dz * gridYawSin
        let relZ = -dx * gridYawSin + dz * gridYawCos
        return grid.accumulate(
            relX: relX,
            relZ: relZ,
            height: worldY,
            confidence: confidence,
            isHighConfidence: isHighConfidence
        )
    }

    // MARK: - Streaming Mesh (실시간, 0.5초 간격)

    /// 스캔 중 실시간 높이 맵 스냅샷 생성 및 콜백
    private func emitStreamingMeshIfNeeded() {
        guard onStreamingMeshUpdate != nil else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastStreamingTime >= streamingInterval else { return }
        lastStreamingTime = now

        let snapshot = generateStreamingSnapshot()
        DispatchQueue.main.async { [weak self] in
            self?.onStreamingMeshUpdate?(snapshot)
        }
    }

    /// 현재 축적 데이터로부터 간이 높이 맵 생성 (필터링 없이 빠른 스냅샷)
    private func generateStreamingSnapshot() -> HeightMapData {
        let baseline = heightBaseline()
        let maps = grid.weightedHeightMap(baseline: baseline)

        return HeightMapData(
            gridWidth:  targetGridWidth,
            gridHeight: targetGridHeight,
            cellSize:   targetCellSize,
            heightMap:  maps.heights,
            confidenceMap: maps.confidence,
            uncertaintyMap: maps.uncertainty,
            tiltPitch:  tiltSampleCount > 0 ? cumulativeTiltPitch / Double(tiltSampleCount) : 0,
            tiltRoll:   tiltSampleCount > 0 ? cumulativeTiltRoll / Double(tiltSampleCount) : 0,
            totalPointCount: totalContributedPoints,
            originX: gridOriginX,
            originZ: gridOriginZ,
            groundY: baseline,
            gridYaw: gridYaw,
            cameraHeight: Double(fusedCameraHeight)
        )
    }

    private func heightBaseline() -> Double {
        if groundDetected { return Double(detectedGroundY) }
        return grid.minAverageHeight() ?? 0
    }

    // MARK: - Depth Image (실시간, 약 2fps)

    private func emitDepthImageThrottled(frame: ARFrame, pitchDeg: Double, rollDeg: Double) {
        let now = Date().timeIntervalSince1970
        guard now - lastDepthImageTime >= 0.5 else { return }
        lastDepthImageTime = now

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        // ARFrame의 픽셀 버퍼를 비동기 클로저에 보유하면 ARKit 버퍼 풀이 고갈되어
        // 프레임 드롭이 발생할 수 있으므로, 복사본을 만들어 전달한다 (256×192 ≈ 250KB, 2fps)
        guard let depthBuf = LiDARScanner.copyPixelBuffer(depthData.depthMap) else { return }
        let confBuf = depthData.confidenceMap.flatMap { LiDARScanner.copyPixelBuffer($0) }
        let pitch    = pitchDeg
        let roll     = rollDeg

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let img = DepthImageRenderer.renderDepthImage(
                depthBuffer:      depthBuf,
                confidenceBuffer: confBuf,
                minDepth:  0.15,
                maxDepth:  10.0,
                tiltPitch: pitch,
                tiltRoll:  roll
            ) else { return }

            DispatchQueue.main.async {
                self.onDepthImageReady?(img)
            }
        }
    }

    /// CVPixelBuffer 깊은 복사 (단일 평면 버퍼 전용: DepthFloat32 / OneComponent8)
    private static func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width  = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)

        var dstOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                         nil, &dstOpt)
        guard status == kCVReturnSuccess, let dst = dstOpt else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)

        if srcStride == dstStride {
            memcpy(dstBase, srcBase, srcStride * height)
        } else {
            let rowBytes = min(srcStride, dstStride)
            for row in 0..<height {
                memcpy(dstBase.advanced(by: row * dstStride),
                       srcBase.advanced(by: row * srcStride),
                       rowBytes)
            }
        }
        return dst
    }

    // MARK: - Quality Assessment

    private func updateQuality(frame: ARFrame) {
        var quality = MeasurementQuality()

        if let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
            quality.averageConfidence = calculateAverageConfidence(depthData.confidenceMap)
        }

        if grid.filledCellCount > 0 {
            quality.coveragePercent = min(1.0, Double(grid.filledCellCount) / Double(targetCoverageCellCount()))
            quality.averageSamplesPerCell = grid.averageSamplesPerCell
        } else {
            quality.coveragePercent = 0
            quality.averageSamplesPerCell = 0
        }

        quality.stabilityScore = calculateStability()

        if let le = frame.lightEstimate {
            quality.lightingScore = min(1.0, le.ambientIntensity / 1000.0)
        }

        let cam  = frame.camera.transform
        let fwdY = -cam.columns.2.y
        let targetFwdY = 0.5
        let deviation = abs(Double(fwdY) - targetFwdY)
        quality.tiltScore = max(0.0, 1.0 - deviation / 0.5)

        latestQuality = quality
        onQualityUpdate?(quality)
    }

    // MARK: - Auto Stop

    private func checkAutoStop() {
        guard !autoStopSignaled else { return }

        let q = latestQuality
        let hardLimitReached = elapsedSinceScanStart() >= maxDataCollectionDuration
        let reliableEnough = normalScanFrameCount >= minFramesForReliableScan
                         && normalScanElapsed >= minReliableScanDuration
                         && q.coveragePercent    > 0.35
                         && q.averageConfidence  > 0.45
                         && q.stabilityScore     > 0.20
                         && q.tiltScore          > 0.12
                         && q.averageSamplesPerCell >= 1.2

        if hardLimitReached {
            signalAutoStop()
            return
        }

        if reliableEnough {
            autoQualityFrames += 1
            if autoQualityFrames >= autoQualityRequired {
                signalAutoStop()
            }
        } else {
            autoQualityFrames = 0
        }
    }

    private func updateNormalScanTimer(now: TimeInterval, frame: ARFrame, pointingDownScore: Double) {
        if isNormalScanState(frame: frame, pointingDownScore: pointingDownScore) {
            if normalScanStartTimestamp == nil {
                normalScanStartTimestamp = now
            }
            normalScanFrameCount += 1
        }

        if let startedAt = normalScanStartTimestamp {
            normalScanElapsed = min(maxDataCollectionDuration, max(0, now - startedAt))
        }
    }

    private func isNormalScanState(frame: ARFrame, pointingDownScore: Double) -> Bool {
        guard case .normal = frame.camera.trackingState else { return false }

        let q = latestQuality
        return pointingDownScore > 0.08
            && q.coveragePercent > 0.001
            && q.averageConfidence > 0.30
            && q.tiltScore > 0.08
            && q.averageSamplesPerCell > 0.1
    }

    private func scheduleScanStartHardStop(startedAt: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDataCollectionDuration) { [weak self] in
            self?.processingQueue.async {
                guard let self,
                      self.isScanning,
                      self.scanDeadlineToken == startedAt else { return }
                self.signalAutoStop()
            }
        }
    }

    private func elapsedSinceScanStart() -> TimeInterval {
        guard scanStartTimestamp > 0 else { return 0 }
        return Date().timeIntervalSince1970 - scanStartTimestamp
    }

    private func signalAutoStop() {
        guard !autoStopSignaled else { return }
        autoStopSignaled = true
        let expectedToken = scanDeadlineToken
        DispatchQueue.main.async { [weak self] in
            self?.onAutoStopReady?()
        }
        processingQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.finishScanIfNeeded(expectedToken: expectedToken)
        }
    }

    private func targetCoverageCellCount() -> Int {
        // 3m×10m 그리드는 한 위치에서 전부 보이지 않으므로 60%를 목표 커버리지로 본다
        let cells = Double(targetGridWidth * targetGridHeight) * 0.6
        return max(1, Int(cells.rounded()))
    }

    private func calculateAverageConfidence(_ confMap: CVPixelBuffer?) -> Double {
        guard let confMap else { return 0 }
        CVPixelBufferLockBaseAddress(confMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) }

        let w = CVPixelBufferGetWidth(confMap)
        let h = CVPixelBufferGetHeight(confMap)
        guard let base = CVPixelBufferGetBaseAddress(confMap) else { return 0 }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let rowStride = CVPixelBufferGetBytesPerRow(confMap)
        var total = 0.0
        let step = 8
        var count = 0

        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                total += Double(ptr[y * rowStride + x]) / 2.0
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    private func calculateStability() -> Double {
        guard recentPoses.count > 5 else { return 0 }
        var totalMovement = 0.0
        for i in 1 ..< recentPoses.count {
            let p = recentPoses[i - 1]; let c = recentPoses[i]
            let dx = Double(c.columns.3.x - p.columns.3.x)
            let dy = Double(c.columns.3.y - p.columns.3.y)
            let dz = Double(c.columns.3.z - p.columns.3.z)
            totalMovement += sqrt(dx*dx + dy*dy + dz*dz)
        }
        let avg = totalMovement / Double(recentPoses.count - 1)
        return max(0, min(1.0, 1.0 - avg * 50))
    }

    // MARK: - Final Processing

    private func processFinalHeightMap() {
        let resultDeadline = scanStartTimestamp > 0
            ? scanStartTimestamp + maxScanToResultDuration
            : Date().timeIntervalSince1970 + finalProcessingReserve

        // 가중 평균으로 높이 계산
        let baseline = heightBaseline()
        let maps = grid.weightedHeightMap(baseline: baseline)

        let avgPitch = tiltSampleCount > 0 ? cumulativeTiltPitch / Double(tiltSampleCount) : 0
        let avgRoll  = tiltSampleCount > 0 ? cumulativeTiltRoll  / Double(tiltSampleCount) : 0

        var heightMap = HeightMapData(
            gridWidth:  targetGridWidth,
            gridHeight: targetGridHeight,
            cellSize:   targetCellSize,
            heightMap:  maps.heights,
            confidenceMap: maps.confidence,
            uncertaintyMap: maps.uncertainty,
            tiltPitch:  avgPitch,
            tiltRoll:   avgRoll,
            totalPointCount: totalContributedPoints,
            originX: gridOriginX,
            originZ: gridOriginZ,
            groundY: baseline,
            gridYaw: gridYaw,
            cameraHeight: Double(fusedCameraHeight)
        )

        ensureMinimumValidTerrain(&heightMap)

        if hasProcessingBudget(until: resultDeadline, reserve: 0.45) {
            removeStatisticalOutliers(&heightMap)
        }

        if hasProcessingBudget(until: resultDeadline, reserve: 0.30) {
            interpolateEmptyCells(&heightMap, maxPasses: 2)
        } else if hasProcessingBudget(until: resultDeadline, reserve: 0.12) {
            interpolateEmptyCells(&heightMap, maxPasses: 1)
        }

        if hasProcessingBudget(until: resultDeadline, reserve: 0.22) {
            applyMedianFilterAccelerated(&heightMap)
        }

        if hasProcessingBudget(until: resultDeadline, reserve: 0.08) {
            heightMap.applyGaussianSmoothing(kernelSize: 3)
        }

        ensureMinimumValidTerrain(&heightMap)

        DispatchQueue.main.async { [weak self] in
            self?.onScanComplete?(heightMap)
        }
    }

    private func hasProcessingBudget(until deadline: TimeInterval, reserve: TimeInterval) -> Bool {
        Date().timeIntervalSince1970 < deadline - reserve
    }

    private func ensureMinimumValidTerrain(_ data: inout HeightMapData) {
        let hasValidCell = data.confidenceMap.contains { $0 > 0.01 }
        guard !hasValidCell else { return }
        data.heightMap = Array(repeating: 0.0, count: data.gridWidth * data.gridHeight)
        data.confidenceMap = Array(repeating: 0.05, count: data.gridWidth * data.gridHeight)
        data.uncertaintyMap = Array(repeating: 0.0, count: data.gridWidth * data.gridHeight)
    }

    // MARK: - Statistical Outlier Removal (CoreML 대체 고급 노이즈 필터)

    /// 각 셀의 높이가 주변 이웃의 통계적 분포에서 크게 벗어나면 제거
    /// - 5×5 영역의 평균/표준편차를 계산하여 2σ 이상 벗어나는 셀을 보간 값으로 대체
    private func removeStatisticalOutliers(_ data: inout HeightMapData) {
        let w = data.gridWidth, h = data.gridHeight
        let radius = 2  // 5×5 영역
        let sigmaThreshold = 2.0

        var cleaned = data.heightMap
        var cleanedConf = data.confidenceMap

        for y in radius..<(h - radius) {
            for x in radius..<(w - radius) {
                guard data.getConfidence(x: x, y: y) > 0.01 else { continue }

                // 주변 5×5 영역의 유효 셀에서 통계 계산
                var values: [Double] = []
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx, ny = y + dy
                        if data.getConfidence(x: nx, y: ny) > 0.01 {
                            values.append(data.getHeight(x: nx, y: ny))
                        }
                    }
                }

                guard values.count >= 5 else { continue }

                // 평균 계산 (vDSP 활용)
                var mean: Double = 0
                vDSP_meanvD(values, 1, &mean, vDSP_Length(values.count))

                // 표준편차 계산
                var variance: Double = 0
                var tempValues = values.map { ($0 - mean) * ($0 - mean) }
                vDSP_meanvD(&tempValues, 1, &variance, vDSP_Length(tempValues.count))
                let stdDev = sqrt(variance)

                // 현재 셀이 2σ 이상 벗어나면 이상치로 판정
                let currentH = data.getHeight(x: x, y: y)
                if stdDev > 0.0001 && abs(currentH - mean) > sigmaThreshold * stdDev {
                    // 이상치 → 주변 평균으로 대체하고 신뢰도 감소
                    cleaned[y * w + x] = mean
                    cleanedConf[y * w + x] = min(cleanedConf[y * w + x], 0.4)
                }
            }
        }

        data.heightMap = cleaned
        data.confidenceMap = cleanedConf
    }

    // MARK: - Filters (Accelerate 최적화)

    /// 3×3 미디언 필터 — vDSP 가속 정렬 기반
    /// vImage 호환 메모리 레이아웃으로 행 단위 캐시 친화적 처리
    private func applyMedianFilterAccelerated(_ data: inout HeightMapData) {
        var filtered = data.heightMap
        let w = data.gridWidth, h = data.gridHeight

        // 행 단위 캐시 친화적 미디언 필터 (vDSP 정렬 활용)
        var window = [Double](repeating: 0, count: 9)

        for y in 1 ..< (h - 1) {
            for x in 1 ..< (w - 1) {
                guard data.getConfidence(x: x, y: y) > 0.01 else { continue }
                var count = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        if data.getConfidence(x: x+dx, y: y+dy) > 0.01 {
                            window[count] = data.getHeight(x: x+dx, y: y+dy)
                            count += 1
                        }
                    }
                }
                if count > 0 {
                    vDSP_vsortD(&window, vDSP_Length(count), 1)
                    filtered[y * w + x] = window[count / 2]
                }
            }
        }
        data.heightMap = filtered
    }

    /// 빈 셀 주변 값으로 보간. 전체 5초 마감 내 완료되도록 호출부에서 반복 횟수를 제한한다.
    private func interpolateEmptyCells(_ data: inout HeightMapData, maxPasses: Int) {
        for _ in 0 ..< maxPasses {
            var hasEmpty = false
            for y in 0 ..< data.gridHeight {
                for x in 0 ..< data.gridWidth {
                    guard data.getConfidence(x: x, y: y) < 0.01 else { continue }
                    hasEmpty = true
                    var sum = 0.0, wsum = 0.0
                    for dy in -2...2 {
                        for dx in -2...2 {
                            if dx == 0 && dy == 0 { continue }
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < data.gridWidth,
                                  ny >= 0, ny < data.gridHeight else { continue }
                            let c = data.getConfidence(x: nx, y: ny)
                            if c > 0.01 {
                                let d = sqrt(Double(dx*dx + dy*dy))
                                let w = c / d
                                sum  += data.getHeight(x: nx, y: ny) * w
                                wsum += w
                            }
                        }
                    }
                    if wsum > 0 {
                        data.setHeight(x: x, y: y, value: sum / wsum)
                        data.setConfidence(x: x, y: y, value: 0.3)
                    }
                }
            }
            if !hasEmpty { break }
        }
    }
}
