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
    private var isScanning = false

    // 높이 맵 그리드 설정 (20m×20m, 5cm 해상도)
    private let targetGridWidth  = 400
    private let targetGridHeight = 400
    private let targetCellSize: Double = 0.05   // 5cm → 20m×20m 커버리지
    // 스캔 ROI: 오버레이 가이드와 동일한 중앙 직사각형 비율
    private let scanRectWidthRatio: Double = 0.82
    private let scanRectHeightRatio: Double = 0.56

    // 프레임 축적 데이터
    private var accumulatedHeights:    [[Double]] = []
    private var accumulatedCounts:     [[Int]]    = []
    private var accumulatedConfidence: [[Double]] = []

    // 포즈 / 조명 이력
    private var recentPoses:          [simd_float4x4] = []
    private var recentLightEstimates: [Double]         = []
    private var frameCount = 0
    private let minFramesForScan = 30

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
    /// 마지막 패닝 체크 시 카메라 위치
    private var lastPanCameraX: Double = 0
    private var lastPanCameraZ: Double = 0
    /// 그리드 패닝 임계 거리 (카메라가 그리드 중심에서 이 거리 이상 이동 시 패닝)
    private let gridPanThreshold: Double = 4.0

    // ── 커버리지 증분 추적 (O(1) 업데이트) ──────────────────────────────
    private var filledCellCount = 0
    private var gridMinX = 0
    private var gridMaxX = 0
    private var gridMinZ = 0
    private var gridMaxZ = 0
    private var gridBBoxInitialized = false
    /// 채워진 셀 추적 (빠른 스파스 반복용)
    private var filledCells = Set<Int>()

    // ── 자동 종료 추적 ────────────────────────────────────────────────────
    private var autoQualityFrames = 0
    private let autoQualityRequired = 3
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
        resetAccumulators()
        isScanning = true
        frameCount = 0
        // 바로미터 기준 재설정
        barometerBaseAltitude = nil
        barometerRelativeAlt = 0
    }

    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processFinalHeightMap()
        }
    }

    private func resetAccumulators() {
        let w = targetGridWidth, h = targetGridHeight
        accumulatedHeights    = Array(repeating: Array(repeating: 0.0, count: w), count: h)
        accumulatedCounts     = Array(repeating: Array(repeating: 0,   count: w), count: h)
        accumulatedConfidence = Array(repeating: Array(repeating: 0.0, count: w), count: h)
        meshVertices.removeAll()
        recentPoses.removeAll()
        recentLightEstimates.removeAll()
        cumulativeTiltPitch    = 0
        cumulativeTiltRoll     = 0
        tiltSampleCount        = 0
        totalContributedPoints = 0
        autoQualityFrames      = 0
        gridOriginX            = 0
        gridOriginZ            = 0
        gridOriginSet          = false
        lastPanCameraX         = 0
        lastPanCameraZ         = 0
        filledCellCount        = 0
        filledCells.removeAll()
        gridMinX               = 0
        gridMaxX               = 0
        gridMinZ               = 0
        gridMaxZ               = 0
        gridBBoxInitialized    = false
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

        cumulativeTiltPitch += pitchDeg
        cumulativeTiltRoll  += rollDeg
        tiltSampleCount     += 1

        guard pointingDownScore > 0.15 else {
            updateQuality(frame: frame)
            return
        }

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
            // 첫 유효 프레임: 카메라 전방 10m 지점을 그리드 중심으로 설정
            let camFwd = frame.camera.transform.columns.2
            let fwdX = -Double(camFwd.x)
            let fwdZ = -Double(camFwd.z)
            let fwdLen = sqrt(fwdX * fwdX + fwdZ * fwdZ)
            let halfRange = Double(targetGridWidth) * targetCellSize / 2.0
            if fwdLen > 0.01 {
                gridOriginX = camPosX + fwdX / fwdLen * halfRange
                gridOriginZ = camPosZ + fwdZ / fwdLen * halfRange
            } else {
                gridOriginX = camPosX
                gridOriginZ = camPosZ
            }
            gridOriginSet = true
            lastPanCameraX = camPosX
            lastPanCameraZ = camPosZ
        } else {
            // 스캔 중 카메라 이동 시 그리드 원점 패닝
            updateGridOriginIfNeeded(cameraX: camPosX, cameraZ: camPosZ)
        }

        // 깊이 처리
        processDepthData(frame: frame, tiltQuality: pointingDownScore)

        // 진행률 업데이트
        let progress = min(1.0, Double(frameCount) / Double(minFramesForScan))
        onScanProgress?(progress)

        // 실시간 깊이 이미지 (약 2fps)
        emitDepthImageThrottled(frame: frame, pitchDeg: pitchDeg, rollDeg: rollDeg)

        // 실시간 스트리밍 메쉬 업데이트 (0.5초 간격)
        emitStreamingMeshIfNeeded()

        updateQuality(frame: frame)
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

    /// 카메라가 그리드 중심에서 임계 거리 이상 이동하면 그리드를 시프트
    private func updateGridOriginIfNeeded(cameraX: Double, cameraZ: Double) {
        let dx = cameraX - gridOriginX
        let dz = cameraZ - gridOriginZ

        // 카메라가 그리드 중심에서 임계 거리 이상 이동했는지 확인
        guard abs(dx) > gridPanThreshold || abs(dz) > gridPanThreshold else { return }

        // 시프트할 셀 수 계산
        let shiftCellsX = Int(dx / targetCellSize)
        let shiftCellsZ = Int(dz / targetCellSize)

        guard shiftCellsX != 0 || shiftCellsZ != 0 else { return }

        // 그리드 데이터 시프트
        shiftGrid(dx: shiftCellsX, dz: shiftCellsZ)

        // 원점 업데이트
        gridOriginX += Double(shiftCellsX) * targetCellSize
        gridOriginZ += Double(shiftCellsZ) * targetCellSize
    }

    /// 그리드 데이터를 (dx, dz) 셀만큼 시프트 (기존 데이터 유지, 새 영역은 0으로 초기화)
    private func shiftGrid(dx: Int, dz: Int) {
        let w = targetGridWidth, h = targetGridHeight

        var newHeights    = Array(repeating: Array(repeating: 0.0, count: w), count: h)
        var newCounts     = Array(repeating: Array(repeating: 0,   count: w), count: h)
        var newConfidence = Array(repeating: Array(repeating: 0.0, count: w), count: h)
        var newFilledCells = Set<Int>()

        for z in 0..<h {
            let srcZ = z + dz
            guard srcZ >= 0, srcZ < h else { continue }
            for x in 0..<w {
                let srcX = x + dx
                guard srcX >= 0, srcX < w else { continue }
                newHeights[z][x]    = accumulatedHeights[srcZ][srcX]
                newCounts[z][x]     = accumulatedCounts[srcZ][srcX]
                newConfidence[z][x] = accumulatedConfidence[srcZ][srcX]
                if newCounts[z][x] > 0 {
                    newFilledCells.insert(z * w + x)
                }
            }
        }

        accumulatedHeights    = newHeights
        accumulatedCounts     = newCounts
        accumulatedConfidence = newConfidence
        filledCells           = newFilledCells
        filledCellCount       = filledCells.count

        // 바운딩 박스 재계산
        recalculateBBox()
    }

    private func recalculateBBox() {
        gridBBoxInitialized = false
        for idx in filledCells {
            let z = idx / targetGridWidth
            let x = idx % targetGridWidth
            if !gridBBoxInitialized {
                gridMinX = x; gridMaxX = x
                gridMinZ = z; gridMaxZ = z
                gridBBoxInitialized = true
            } else {
                if x < gridMinX { gridMinX = x }
                if x > gridMaxX { gridMaxX = x }
                if z < gridMinZ { gridMinZ = z }
                if z > gridMaxZ { gridMaxZ = z }
            }
        }
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

        let intrinsics       = frame.camera.intrinsics
        let cameraTransform  = frame.camera.transform
        let fx = intrinsics[0][0];  let fy = intrinsics[1][1]
        let cx = intrinsics[2][0];  let cy = intrinsics[2][1]

        // step=1: 모든 픽셀 처리로 최대 정밀도
        let step = 1
        var localPoints = 0
        let roiMinU = (1.0 - scanRectWidthRatio) * 0.5
        let roiMaxU = 1.0 - roiMinU
        let roiCenterV = 0.5 - (18.0 / 844.0) // 오버레이의 상단 오프셋(-18pt)와 동일한 중심 보정
        let roiMinV = roiCenterV - (scanRectHeightRatio * 0.5)
        let roiMaxV = roiCenterV + (scanRectHeightRatio * 0.5)

        // 카메라 높이에 따른 유효 최대 거리 동적 계산 (바로미터 융합 높이 사용)
        let effectiveHeight = max(estimatedCameraHeight, fusedCameraHeight)
        let dynamicMaxDepth: Float = min(10.0, effectiveHeight / 0.15 + 2.0)

        for v in stride(from: 0, to: dh, by: step) {
            for u in stride(from: 0, to: dw, by: step) {
                let nu = Double(u) / Double(dw)
                let nv = Double(v) / Double(dh)
                guard nu >= roiMinU, nu <= roiMaxU, nv >= roiMinV, nv <= roiMaxV else { continue }

                let idx        = v * dw + u
                let depth      = depthPtr[idx]
                let confidence = confPtr[idx]

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

                mapToGrid(worldX: Double(worldPt.x),
                          worldY: Double(worldPt.y),
                          worldZ: Double(worldPt.z),
                          confidence: confWeight)
                localPoints += 1
            }
        }

        totalContributedPoints += localPoints
    }

    // MARK: - Mesh Processing

    private func extractMeshVertices(_ meshAnchor: ARMeshAnchor) {
        let geo    = meshAnchor.geometry
        let verts  = geo.vertices
        let stride = verts.stride
        let buf    = verts.buffer.contents()
        let tfm    = meshAnchor.transform

        for i in 0 ..< verts.count {
            let ptr    = buf.advanced(by: i * stride)
            let v      = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let world  = tfm * SIMD4<Float>(v, 1.0)
            mapToGrid(worldX: Double(world.x),
                      worldY: Double(world.y),
                      worldZ: Double(world.z),
                      confidence: 0.8)
        }
    }

    // MARK: - Grid Mapping

    private func mapToGrid(worldX: Double, worldY: Double, worldZ: Double, confidence: Double) {
        let gridRangeX = Double(targetGridWidth)  * targetCellSize / 2.0
        let gridRangeZ = Double(targetGridHeight) * targetCellSize / 2.0

        let relX = worldX - gridOriginX
        let relZ = worldZ - gridOriginZ

        let gx = Int((relX + gridRangeX) / targetCellSize)
        let gz = Int((relZ + gridRangeZ) / targetCellSize)

        guard gx >= 0, gx < targetGridWidth,
              gz >= 0, gz < targetGridHeight else { return }

        let cellIdx = gz * targetGridWidth + gx

        // 새로 채워지는 셀이면 커버리지 갱신
        if accumulatedCounts[gz][gx] == 0 {
            filledCellCount += 1
            filledCells.insert(cellIdx)
            if !gridBBoxInitialized {
                gridMinX = gx; gridMaxX = gx
                gridMinZ = gz; gridMaxZ = gz
                gridBBoxInitialized = true
            } else {
                if gx < gridMinX { gridMinX = gx }
                if gx > gridMaxX { gridMaxX = gx }
                if gz < gridMinZ { gridMinZ = gz }
                if gz > gridMaxZ { gridMaxZ = gz }
            }
        }

        accumulatedHeights[gz][gx]    += worldY * confidence
        accumulatedConfidence[gz][gx] += confidence
        accumulatedCounts[gz][gx]     += 1
    }

    // MARK: - Streaming Mesh (실시간, 0.5초 간격)

    /// 스캔 중 실시간 높이 맵 스냅샷 생성 및 콜백
    private func emitStreamingMeshIfNeeded() {
        guard onStreamingMeshUpdate != nil else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastStreamingTime >= streamingInterval else { return }
        lastStreamingTime = now

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.generateStreamingSnapshot()
            DispatchQueue.main.async {
                self.onStreamingMeshUpdate?(snapshot)
            }
        }
    }

    /// 현재 축적 데이터로부터 간이 높이 맵 생성 (필터링 없이 빠른 스냅샷)
    private func generateStreamingSnapshot() -> HeightMapData {
        var heightFlat = [Double](repeating: 0, count: targetGridWidth * targetGridHeight)
        var confFlat   = [Double](repeating: 0, count: targetGridWidth * targetGridHeight)

        for idx in filledCells {
            let y = idx / targetGridWidth
            let x = idx % targetGridWidth
            let wsum = accumulatedConfidence[y][x]
            if wsum > 0 {
                heightFlat[idx] = accumulatedHeights[y][x] / wsum
                confFlat[idx]   = min(1.0, wsum / 5.0)
            }
        }

        return HeightMapData(
            gridWidth:  targetGridWidth,
            gridHeight: targetGridHeight,
            cellSize:   targetCellSize,
            heightMap:  heightFlat,
            confidenceMap: confFlat,
            tiltPitch:  tiltSampleCount > 0 ? cumulativeTiltPitch / Double(tiltSampleCount) : 0,
            tiltRoll:   tiltSampleCount > 0 ? cumulativeTiltRoll / Double(tiltSampleCount) : 0,
            totalPointCount: totalContributedPoints,
            originX: gridOriginX,
            originZ: gridOriginZ,
            groundY: Double(detectedGroundY),
            cameraHeight: Double(fusedCameraHeight)
        )
    }

    // MARK: - Depth Image (실시간, 약 2fps)

    private func emitDepthImageThrottled(frame: ARFrame, pitchDeg: Double, rollDeg: Double) {
        let now = Date().timeIntervalSince1970
        guard now - lastDepthImageTime >= 0.5 else { return }
        lastDepthImageTime = now

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthBuf = depthData.depthMap
        let confBuf  = depthData.confidenceMap
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

    // MARK: - Quality Assessment

    private func updateQuality(frame: ARFrame) {
        var quality = MeasurementQuality()

        if let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
            quality.averageConfidence = calculateAverageConfidence(depthData.confidenceMap)
        }

        if filledCellCount > 0 && gridBBoxInitialized {
            let bboxArea = (gridMaxX - gridMinX + 1) * (gridMaxZ - gridMinZ + 1)
            quality.coveragePercent = bboxArea > 0
                ? min(1.0, Double(filledCellCount) / Double(bboxArea))
                : 0
        } else {
            quality.coveragePercent = 0
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
        guard frameCount >= minFramesForScan else { return }

        let q = latestQuality
        let isGood = q.coveragePercent    > 0.70
                  && q.averageConfidence  > 0.60
                  && q.stabilityScore     > 0.50
                  && q.tiltScore          > 0.20

        if isGood {
            autoQualityFrames += 1
            if autoQualityFrames >= autoQualityRequired {
                isScanning = false
                DispatchQueue.main.async { [weak self] in
                    self?.onAutoStopReady?()
                }
            }
        } else {
            autoQualityFrames = 0
        }
    }

    private func calculateAverageConfidence(_ confMap: CVPixelBuffer?) -> Double {
        guard let confMap else { return 0 }
        CVPixelBufferLockBaseAddress(confMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) }

        let w = CVPixelBufferGetWidth(confMap)
        let h = CVPixelBufferGetHeight(confMap)
        guard let base = CVPixelBufferGetBaseAddress(confMap) else { return 0 }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        let step = 8
        var count = 0

        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                total += Double(ptr[y * w + x]) / 2.0
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
        // 가중 평균으로 높이 계산
        var heightFlat = [Double](repeating: 0, count: targetGridWidth * targetGridHeight)
        var confFlat   = [Double](repeating: 0, count: targetGridWidth * targetGridHeight)

        for y in 0 ..< targetGridHeight {
            for x in 0 ..< targetGridWidth {
                let idx = y * targetGridWidth + x
                let wsum = accumulatedConfidence[y][x]
                if wsum > 0 {
                    heightFlat[idx] = accumulatedHeights[y][x] / wsum
                    confFlat[idx]   = min(1.0, wsum / 5.0)
                }
            }
        }

        let avgPitch = tiltSampleCount > 0 ? cumulativeTiltPitch / Double(tiltSampleCount) : 0
        let avgRoll  = tiltSampleCount > 0 ? cumulativeTiltRoll  / Double(tiltSampleCount) : 0

        var heightMap = HeightMapData(
            gridWidth:  targetGridWidth,
            gridHeight: targetGridHeight,
            cellSize:   targetCellSize,
            heightMap:  heightFlat,
            confidenceMap: confFlat,
            tiltPitch:  avgPitch,
            tiltRoll:   avgRoll,
            totalPointCount: totalContributedPoints,
            originX: gridOriginX,
            originZ: gridOriginZ,
            groundY: Double(detectedGroundY),
            cameraHeight: Double(fusedCameraHeight)
        )

        // 0. 통계적 이상치 제거 (CoreML 대체)
        removeStatisticalOutliers(&heightMap)

        // 1. 빈 셀 보간
        interpolateEmptyCells(&heightMap)

        // 2. 미디언 필터 (vDSP 가속, 이상값 제거)
        applyMedianFilterAccelerated(&heightMap)

        // 3. 가우시안 스무딩 (9×9 커널)
        heightMap.applyGaussianSmoothing(kernelSize: 9)

        onScanComplete?(heightMap)
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

    /// 빈 셀 주변 값으로 보간 (최대 5회 반복, 스파스 셀 추적으로 효율화)
    private func interpolateEmptyCells(_ data: inout HeightMapData) {
        for _ in 0 ..< 5 {
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
