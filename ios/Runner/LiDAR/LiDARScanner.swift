import Foundation
import ARKit
import CoreVideo
import Accelerate

/// LiDAR 스캐너 - ARKit SceneDepth를 이용한 실제 LiDAR 데이터 수집
///
/// 주요 개선사항:
/// - 깊이 맵 **전체 픽셀** 처리 (step 4→2, 2배 세밀도)
/// - **자이로/중력 벡터** 기반 카메라 기울기 품질 가중치 적용
/// - 기울기가 나쁜 프레임(거의 수평) 자동 제외로 정확도 향상
/// - 프레임마다 false-color **깊이 이미지** 생성 → `onDepthImageReady` 콜백
/// - 스캔 완료 시 tiltPitch/tiltRoll/totalPointCount 를 HeightMapData에 기록
@available(iOS 14.0, *)
class LiDARScanner: NSObject, ARSessionDelegate {

    // MARK: - Properties

    private let session: ARSession
    private var isScanning = false

    // 높이 맵 그리드 설정 (15m×15m, 5cm 해상도)
    private let targetGridWidth  = 300
    private let targetGridHeight = 300
    private let targetCellSize: Double = 0.05   // 5cm → 15m×15m 커버리지

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
    /// 스캔 기간 중 누적 pitch (도)
    private var cumulativeTiltPitch: Double = 0
    /// 스캔 기간 중 누적 roll (도)
    private var cumulativeTiltRoll:  Double = 0
    /// 기울기 샘플 카운트 (평균 계산용)
    private var tiltSampleCount: Int = 0
    /// 스캔 전체 기여 포인트 합계
    private var totalContributedPoints: Int = 0
    /// 마지막으로 깊이 이미지를 생성한 시각 (과부하 방지)
    private var lastDepthImageTime: TimeInterval = 0
    /// 최신 pitch (°) - 품질 UI 표시용
    private(set) var currentTiltPitch: Double = 0
    /// 최신 roll (°) - 품질 UI 표시용
    private(set) var currentTiltRoll:  Double = 0

    // ── 그리드 동적 원점 (카메라 위치 기반) ──────────────────────────────
    private var gridOriginX: Double = 0
    private var gridOriginZ: Double = 0
    private var gridOriginSet = false

    // ── 커버리지 증분 추적 (O(1) 업데이트) ──────────────────────────────
    private var filledCellCount = 0
    private var gridMinX = 0
    private var gridMaxX = 0
    private var gridMinZ = 0
    private var gridMaxZ = 0
    private var gridBBoxInitialized = false

    // ── 자동 종료 추적 ────────────────────────────────────────────────────
    private var autoQualityFrames = 0     // 연속 고품질 프레임 카운터
    private let autoQualityRequired = 3   // 연속 N 프레임 충족 시 자동 종료
    private var latestQuality = MeasurementQuality()

    // MARK: - Callbacks

    /// 품질 지표 업데이트 (메인 스레드)
    var onQualityUpdate:   ((MeasurementQuality) -> Void)?
    /// 스캔 완료 후 HeightMapData (메인 스레드)
    var onScanComplete:    ((HeightMapData) -> Void)?
    /// 매 ARFrame 업데이트 (메인 스레드)
    var onFrameUpdate:     ((ARFrame) -> Void)?
    /// 스캔 진행률 0~1 (메인 스레드)
    var onScanProgress:    ((Double) -> Void)?
    /// 오류 문자열 (메인 스레드)
    var onError:           ((String) -> Void)?
    /// 실시간 false-color 깊이 이미지 (메인 스레드, ~2fps)
    var onDepthImageReady: ((UIImage) -> Void)?
    /// 품질이 충분히 충족되어 자동 종료 준비됨 (메인 스레드)
    var onAutoStopReady:   (() -> Void)?

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

        // 모든 LiDAR 기능 활성화
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
    }

    func pauseSession() {
        session.pause()
    }

    // MARK: - Scan Control

    func startScan() {
        resetAccumulators()
        isScanning = true
        frameCount = 0
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
        filledCellCount        = 0
        gridMinX               = 0
        gridMaxX               = 0
        gridMinZ               = 0
        gridMaxZ               = 0
        gridBBoxInitialized    = false
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
        // 카메라 forward 벡터 (월드 좌표계, -Z 방향)
        let cam  = frame.camera.transform
        // ARKit 월드계에서 Y=up 이므로 카메라 forward의 Y 성분이 아래를 향하는 정도
        let fwdY = -cam.columns.2.y          // 카메라가 아래를 향할수록 양수
        // 0: 수평, 1: 수직 아래
        let pointingDownScore = Double(max(-1, min(1, fwdY)))

        // Euler 각도 기반 pitch/roll (시각화용)
        let euler = frame.camera.eulerAngles
        let pitchDeg = Double(euler.x) * 180.0 / .pi
        let rollDeg  = Double(euler.z) * 180.0 / .pi
        currentTiltPitch = pitchDeg
        currentTiltRoll  = rollDeg

        // 기울기 누적 (평균 계산용)
        cumulativeTiltPitch += pitchDeg
        cumulativeTiltRoll  += rollDeg
        tiltSampleCount     += 1

        // 최소한 약간 아래를 향해야 유효 프레임으로 처리 (완화: 0.4→0.15)
        guard pointingDownScore > 0.15 else {
            updateQuality(frame: frame)
            return
        }

        // 첫 유효 프레임에서 그리드 원점을 카메라 전방 7.5m 지점으로 설정
        // → 그리드가 전방 0m ~ 15m 범위를 커버
        if !gridOriginSet {
            let camPos = frame.camera.transform.columns.3
            let camFwd = frame.camera.transform.columns.2  // ARKit: -Z 방향이 forward
            let fwdX = -Double(camFwd.x)
            let fwdZ = -Double(camFwd.z)
            let fwdLen = sqrt(fwdX * fwdX + fwdZ * fwdZ)
            let halfRange = Double(targetGridWidth) * targetCellSize / 2.0  // 7.5m
            if fwdLen > 0.01 {
                gridOriginX = Double(camPos.x) + fwdX / fwdLen * halfRange
                gridOriginZ = Double(camPos.z) + fwdZ / fwdLen * halfRange
            } else {
                gridOriginX = Double(camPos.x)
                gridOriginZ = Double(camPos.z)
            }
            gridOriginSet = true
        }

        // 깊이 처리 (기울기 품질을 가중치로 사용)
        processDepthData(frame: frame, tiltQuality: pointingDownScore)

        // 진행률 업데이트
        let progress = min(1.0, Double(frameCount) / Double(minFramesForScan))
        onScanProgress?(progress)

        // 실시간 깊이 이미지 (약 2fps)
        emitDepthImageThrottled(frame: frame, pitchDeg: pitchDeg, rollDeg: rollDeg)

        updateQuality(frame: frame)
        checkAutoStop()
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor { extractMeshVertices(mesh) }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor { extractMeshVertices(mesh) }
        }
    }

    // MARK: - Depth Processing

    /// LiDAR 깊이 맵 전체 픽셀을 처리하여 높이 그리드에 축적
    ///
    /// - step=2 → 이전(step=4) 대비 4배 더 많은 포인트, 2배 세밀한 그리드 커버리지
    /// - 자이로 기반 tiltQuality 를 confidence 가중치에 곱해서 기울어진 프레임 영향 감소
    private func processDepthData(frame: ARFrame, tiltQuality: Double) {
        // smoothed depth 우선 (노이즈 감소)
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

        // ── step=4: 셀 크기 2.5cm에서 충분한 밀도 유지, 처리 속도 향상 ──
        let step = 4
        var localPoints = 0

        for v in stride(from: 0, to: dh, by: step) {
            for u in stride(from: 0, to: dw, by: step) {
                let idx        = v * dw + u
                let depth      = depthPtr[idx]
                let confidence = confPtr[idx]

                // 유효 거리 범위 0.1~5.0m (low confidence 포함, 먼 거리의 수직 왜곡 방지)
                guard depth > 0.1, depth < 5.0 else { continue }

                // ARConfidenceLevel: 0=low(0.3), 1=medium(0.6), 2=high(1.0)
                let confBase: Double = confidence == 2 ? 1.0 : confidence == 1 ? 0.6 : 0.3
                // 자이로 기울기 품질 반영
                let confWeight = confBase * tiltQuality

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

        // 카메라 기준 상대 좌표 사용 (고정 월드 원점 대신 동적 그리드 원점)
        let relX = worldX - gridOriginX
        let relZ = worldZ - gridOriginZ

        let gx = Int((relX + gridRangeX) / targetCellSize)
        let gz = Int((relZ + gridRangeZ) / targetCellSize)

        guard gx >= 0, gx < targetGridWidth,
              gz >= 0, gz < targetGridHeight else { return }

        // 새로 채워지는 셀이면 커버리지 바운딩 박스 갱신 (O(1))
        if accumulatedCounts[gz][gx] == 0 {
            filledCellCount += 1
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

    // MARK: - Depth Image (실시간, 약 2fps)

    /// 깊이 맵을 false-color 이미지로 변환하여 onDepthImageReady 콜백 호출 (throttled)
    private func emitDepthImageThrottled(frame: ARFrame, pitchDeg: Double, rollDeg: Double) {
        let now = Date().timeIntervalSince1970
        guard now - lastDepthImageTime >= 0.5 else { return }  // 최대 2fps
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
                maxDepth:  4.0,
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

        // 바운딩 박스 기준 커버리지 (실제 스캔 영역 내 채움률)
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

        // 30° 기준 tilt score: 카메라가 수평 아래 30° → sin(30°) = 0.5 목표
        let cam  = frame.camera.transform
        let fwdY = -cam.columns.2.y
        let targetFwdY = 0.5   // sin(30°)
        let deviation = abs(Double(fwdY) - targetFwdY)
        quality.tiltScore = max(0.0, 1.0 - deviation / 0.5)

        latestQuality = quality
        onQualityUpdate?(quality)
    }

    // MARK: - Auto Stop

    /// 품질 지표가 충분한지 확인하고, 연속으로 충족되면 자동 종료 신호 발생
    private func checkAutoStop() {
        guard frameCount >= minFramesForScan else { return }

        let q = latestQuality
        let isGood = q.coveragePercent    > 0.70   // 완화: 0.85→0.70
                  && q.averageConfidence  > 0.60   // 완화: 0.70→0.60
                  && q.stabilityScore     > 0.50   // 완화: 0.65→0.50
                  && q.tiltScore          > 0.20   // 완화: 0.25→0.20

        if isGood {
            autoQualityFrames += 1
            if autoQualityFrames >= autoQualityRequired {
                // 이미 isScanning=true 상태에서 한 번만 발동
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
                    // 신뢰도: 관측 가중합을 5로 나눠 0~1 범위로 정규화
                    confFlat[idx]   = min(1.0, wsum / 5.0)
                }
            }
        }

        // 평균 기울기 계산
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
            originZ: gridOriginZ
        )

        // 1. 빈 셀 보간
        interpolateEmptyCells(&heightMap)

        // 2. 미디언 필터 (이상값 제거)
        applyMedianFilter(&heightMap)

        // 3. 가우시안 스무딩 (9×9 커널, 중력 보정된 면을 매끄럽게)
        heightMap.applyGaussianSmoothing(kernelSize: 9)

        onScanComplete?(heightMap)
    }

    // MARK: - Filters

    /// 3×3 미디언 필터 - LiDAR 이상값 제거
    private func applyMedianFilter(_ data: inout HeightMapData) {
        var filtered = data.heightMap
        let w = data.gridWidth, h = data.gridHeight

        for y in 1 ..< (h - 1) {
            for x in 1 ..< (w - 1) {
                guard data.getConfidence(x: x, y: y) > 0.01 else { continue }
                var vals: [Double] = []
                for dy in -1...1 {
                    for dx in -1...1 {
                        if data.getConfidence(x: x+dx, y: y+dy) > 0.01 {
                            vals.append(data.getHeight(x: x+dx, y: y+dy))
                        }
                    }
                }
                if !vals.isEmpty {
                    vals.sort()
                    filtered[y * w + x] = vals[vals.count / 2]
                }
            }
        }
        data.heightMap = filtered
    }

    /// 빈 셀 주변 값으로 보간 (최대 5회 반복)
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
