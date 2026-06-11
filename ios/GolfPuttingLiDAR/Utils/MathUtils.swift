import Foundation
import simd
import Accelerate

// MARK: - Vector2 타입
struct Vector2 {
    var x: Double
    var y: Double

    static let zero = Vector2(x: 0, y: 0)

    var length: Double {
        sqrt(x * x + y * y)
    }

    func normalized() -> Vector2 {
        let len = length
        guard len > 1e-10 else { return .zero }
        return Vector2(x: x / len, y: y / len)
    }

    func dot(_ other: Vector2) -> Double {
        x * other.x + y * other.y
    }

    static func + (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: Vector2, rhs: Double) -> Vector2 {
        Vector2(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    static func * (lhs: Double, rhs: Vector2) -> Vector2 {
        Vector2(x: rhs.x * lhs, y: rhs.y * lhs)
    }

    static func / (lhs: Vector2, rhs: Double) -> Vector2 {
        Vector2(x: lhs.x / rhs, y: lhs.y / rhs)
    }
}

// MARK: - HeightMap 데이터 구조
struct HeightMapData {
    let gridWidth: Int
    let gridHeight: Int
    let cellSize: Double // meters
    var heightMap: [Double]
    var confidenceMap: [Double] // 각 셀의 신뢰도 (0~1)
    /// 각 셀의 높이 불확실도(표준편차, meters). 값이 0이면 추정 불가 또는 단일 샘플.
    var uncertaintyMap: [Double] = []

    /// 스캔 시 평균 pitch 각도 (도)
    var tiltPitch: Double = 0
    /// 스캔 시 평균 roll 각도 (도)
    var tiltRoll: Double = 0
    /// 스캔에 기여한 총 포인트 수
    var totalPointCount: Int = 0
    /// 그리드 월드 좌표 원점 X
    var originX: Double = 0
    /// 그리드 월드 좌표 원점 Z
    var originZ: Double = 0
    /// 감지된 지면 Y 좌표
    var groundY: Double = 0
    /// 그리드 로컬 축의 월드 기준 회전각 (rad).
    /// 스캔 시작 시 카메라가 바라보는 방향이 그리드 깊이(+Y/로컬Z) 축이 되도록 설정된다.
    var gridYaw: Double = 0
    /// 추정 카메라 높이 (지면 대비, 미터)
    var cameraHeight: Double = 1.6
    /// 이 HeightMap이 상위 그리드에서 시작하는 X 좌표(m). 원본 그리드는 0.
    var localOriginX: Double = 0
    /// 이 HeightMap이 상위 그리드에서 시작하는 Y/Z 좌표(m). 원본 그리드는 0.
    var localOriginY: Double = 0

    var minHeight: Double {
        validHeightRange.min
    }

    var maxHeight: Double {
        validHeightRange.max
    }

    var widthMeters: Double {
        Double(gridWidth) * cellSize
    }

    var heightMeters: Double {
        Double(gridHeight) * cellSize
    }

    private var validHeightRange: (min: Double, max: Double) {
        guard heightMap.count == confidenceMap.count else {
            let fallback = heightMap.min() ?? 0
            return (fallback, heightMap.max() ?? fallback)
        }

        var minH = Double.greatestFiniteMagnitude
        var maxH = -Double.greatestFiniteMagnitude
        var hasValid = false

        for idx in heightMap.indices where confidenceMap[idx] > 0.01 {
            minH = min(minH, heightMap[idx])
            maxH = max(maxH, heightMap[idx])
            hasValid = true
        }

        if hasValid { return (minH, maxH) }
        let fallback = heightMap.min() ?? 0
        return (fallback, heightMap.max() ?? fallback)
    }

    func getHeight(x: Int, y: Int) -> Double {
        let cx = max(0, min(x, gridWidth - 1))
        let cy = max(0, min(y, gridHeight - 1))
        return heightMap[cy * gridWidth + cx]
    }

    func getConfidence(x: Int, y: Int) -> Double {
        let cx = max(0, min(x, gridWidth - 1))
        let cy = max(0, min(y, gridHeight - 1))
        return confidenceMap[cy * gridWidth + cx]
    }

    mutating func setHeight(x: Int, y: Int, value: Double) {
        guard x >= 0, x < gridWidth, y >= 0, y < gridHeight else { return }
        heightMap[y * gridWidth + x] = value
    }

    mutating func setConfidence(x: Int, y: Int, value: Double) {
        guard x >= 0, x < gridWidth, y >= 0, y < gridHeight else { return }
        confidenceMap[y * gridWidth + x] = value
    }

    func containsLocal(_ point: Vector2) -> Bool {
        point.x >= 0 && point.y >= 0 &&
        point.x < widthMeters && point.y < heightMeters
    }

    func parentToLocal(_ point: Vector2) -> Vector2 {
        Vector2(x: point.x - localOriginX, y: point.y - localOriginY)
    }

    func localToParent(_ point: Vector2) -> Vector2 {
        Vector2(x: point.x + localOriginX, y: point.y + localOriginY)
    }

    // MARK: - 그리드 ↔ 월드 좌표 변환 (yaw 회전 반영)

    /// 그리드 로컬 좌표(meters, 0..widthMeters/0..heightMeters) → 월드 XZ.
    /// 투영(TrajectoryOverlayView)과 역투영(위치 선택)이 반드시 이 변환을 공유해야
    /// 화면-그리드 위치가 일치한다.
    func gridLocalToWorldXZ(_ point: Vector2) -> (x: Double, z: Double) {
        let lx = point.x - widthMeters / 2.0
        let lz = point.y - heightMeters / 2.0
        let c = cos(gridYaw), s = sin(gridYaw)
        return (
            x: originX + lx * c - lz * s,
            z: originZ + lx * s + lz * c
        )
    }

    /// 월드 XZ → 그리드 로컬 좌표 (gridLocalToWorldXZ의 역변환)
    func worldXZToGridLocal(x: Double, z: Double) -> Vector2 {
        let dx = x - originX
        let dz = z - originZ
        let c = cos(gridYaw), s = sin(gridYaw)
        return Vector2(
            x: dx * c + dz * s + widthMeters / 2.0,
            y: -dx * s + dz * c + heightMeters / 2.0
        )
    }

    /// 가우시안 스무딩 적용 (Accelerate vDSP 가속)
    mutating func applyGaussianSmoothing(kernelSize: Int = 3) {
        let sigma = Double(kernelSize) / 3.0
        var kernel: [[Double]] = Array(
            repeating: Array(repeating: 0, count: kernelSize),
            count: kernelSize
        )
        var kernelSum: Double = 0
        let half = kernelSize / 2

        // 커널 생성
        for ky in 0..<kernelSize {
            for kx in 0..<kernelSize {
                let dx = Double(kx - half)
                let dy = Double(ky - half)
                let value = exp(-(dx*dx + dy*dy) / (2 * sigma * sigma))
                kernel[ky][kx] = value
                kernelSum += value
            }
        }

        // 커널 정규화
        for ky in 0..<kernelSize {
            for kx in 0..<kernelSize {
                kernel[ky][kx] /= kernelSum
            }
        }

        // Flatten kernel for potential vDSP usage
        let flatKernel = kernel.flatMap { $0 }
        _ = flatKernel  // 향후 vDSP convolution에 활용 가능

        var smoothed = heightMap

        for y in half..<(gridHeight - half) {
            for x in half..<(gridWidth - half) {
                var weighted = 0.0
                var weightSum = 0.0

                for ky in 0..<kernelSize {
                    for kx in 0..<kernelSize {
                        let sx = x + kx - half
                        let sy = y + ky - half
                        let conf = getConfidence(x: sx, y: sy)
                        let w = kernel[ky][kx] * conf
                        weighted += getHeight(x: sx, y: sy) * w
                        weightSum += w
                    }
                }

                if weightSum > 0 {
                    smoothed[y * gridWidth + x] = weighted / weightSum
                }
            }
        }

        heightMap = smoothed
    }

    // MARK: - LOD (Level of Detail) 서브 리전 추출

    /// 지정 영역을 고해상도(2.5cm)로 리샘플링한 서브 리전 HeightMapData 생성
    /// - Parameters:
    ///   - center: 서브 리전 중심 (그리드 좌표, meters)
    ///   - radius: 서브 리전 반경 (meters)
    ///   - targetCellSize: 목표 셀 크기 (기본 0.025m = 2.5cm)
    /// - Returns: 고해상도 서브 리전 HeightMapData
    func extractHighResSubRegion(center: Vector2, radius: Double,
                                  targetCellSize subCellSize: Double = 0.025) -> HeightMapData {
        let subGridSize = Int(radius * 2.0 / subCellSize)
        guard subGridSize > 0 else { return self }

        var subHeight = [Double](repeating: 0, count: subGridSize * subGridSize)
        var subConf   = [Double](repeating: 0, count: subGridSize * subGridSize)
        var subUncertainty = [Double](repeating: 0, count: subGridSize * subGridSize)

        let startX = center.x - radius
        let startY = center.y - radius
        let originalHalfW = widthMeters / 2.0
        let originalHalfH = heightMeters / 2.0
        let subWidth = Double(subGridSize) * subCellSize
        let subHeightMeters = Double(subGridSize) * subCellSize

        for sy in 0..<subGridSize {
            for sx in 0..<subGridSize {
                let localX = startX + Double(sx) * subCellSize
                let localY = startY + Double(sy) * subCellSize

                // 원본 그리드에서 바이리니어 보간
                let srcFX = localX / cellSize
                let srcFY = localY / cellSize
                let srcX0 = Int(floor(srcFX))
                let srcY0 = Int(floor(srcFY))
                let srcX1 = srcX0 + 1
                let srcY1 = srcY0 + 1
                let tx = srcFX - Double(srcX0)
                let ty = srcFY - Double(srcY0)

                guard srcX0 >= 0, srcX1 < gridWidth,
                      srcY0 >= 0, srcY1 < gridHeight else { continue }

                // 바이리니어 보간 (높이)
                let h00 = getHeight(x: srcX0, y: srcY0)
                let h10 = getHeight(x: srcX1, y: srcY0)
                let h01 = getHeight(x: srcX0, y: srcY1)
                let h11 = getHeight(x: srcX1, y: srcY1)
                let h = h00 * (1-tx) * (1-ty) + h10 * tx * (1-ty) +
                        h01 * (1-tx) * ty     + h11 * tx * ty

                // 바이리니어 보간 (신뢰도)
                let c00 = getConfidence(x: srcX0, y: srcY0)
                let c10 = getConfidence(x: srcX1, y: srcY0)
                let c01 = getConfidence(x: srcX0, y: srcY1)
                let c11 = getConfidence(x: srcX1, y: srcY1)
                let c = c00 * (1-tx) * (1-ty) + c10 * tx * (1-ty) +
                        c01 * (1-tx) * ty     + c11 * tx * ty

                let idx = sy * subGridSize + sx
                subHeight[idx] = h
                subConf[idx]   = c

                if uncertaintyMap.count == heightMap.count {
                    let u00 = uncertaintyMap[srcY0 * gridWidth + srcX0]
                    let u10 = uncertaintyMap[srcY0 * gridWidth + srcX1]
                    let u01 = uncertaintyMap[srcY1 * gridWidth + srcX0]
                    let u11 = uncertaintyMap[srcY1 * gridWidth + srcX1]
                    subUncertainty[idx] = u00 * (1-tx) * (1-ty) + u10 * tx * (1-ty) +
                                          u01 * (1-tx) * ty     + u11 * tx * ty
                }
            }
        }

        return HeightMapData(
            gridWidth: subGridSize,
            gridHeight: subGridSize,
            cellSize: subCellSize,
            heightMap: subHeight,
            confidenceMap: subConf,
            uncertaintyMap: subUncertainty,
            tiltPitch: tiltPitch,
            tiltRoll: tiltRoll,
            totalPointCount: totalPointCount,
            originX: originX + startX - originalHalfW + subWidth / 2.0,
            originZ: originZ + startY - originalHalfH + subHeightMeters / 2.0,
            groundY: groundY,
            gridYaw: gridYaw,
            cameraHeight: cameraHeight,
            localOriginX: startX,
            localOriginY: startY
        )
    }

    /// 볼-홀 경로 주변을 고해상도로 리샘플링 (LOD 적응형 그리드)
    /// - Parameters:
    ///   - ballPos: 볼 위치 (그리드 좌표)
    ///   - holePos: 홀 위치 (그리드 좌표)
    ///   - corridorWidth: 경로 주변 폭 (meters, 기본 1.0m)
    /// - Returns: 고해상도 HeightMapData (2.5cm 셀)
    func extractHighResCorridorLOD(ballPos: Vector2, holePos: Vector2,
                                    corridorWidth: Double = 1.0) -> HeightMapData {
        let mid = (ballPos + holePos) * 0.5
        let dist = (holePos - ballPos).length
        let radius = max(dist / 2.0 + corridorWidth, corridorWidth * 2)
        return extractHighResSubRegion(center: mid, radius: radius, targetCellSize: 0.025)
    }

}

// MARK: - 시뮬레이션 결과
struct SimulationResult {
    let trajectory: [Vector2]
    let aimDirection: Vector2
    let finalDistance: Double
    let breakAmount: Double
}

// MARK: - 스캔 상태
enum ScanState {
    case idle
    case preparing
    case scanning
    case processing
    case ready(HeightMapData)
    case error(String)
}

// MARK: - 측정 품질 체크
struct MeasurementQuality {
    var averageConfidence: Double = 0
    var coveragePercent: Double = 0
    var stabilityScore: Double = 0
    var lightingScore: Double = 0
    var tiltScore: Double = 0
    var averageSamplesPerCell: Double = 0

    var isOptimal: Bool {
        averageConfidence > 0.55 &&
        coveragePercent > 0.35 &&
        stabilityScore > 0.25 &&
        lightingScore > 0.2 &&
        tiltScore > 0.12 &&
        averageSamplesPerCell >= 1.2
    }

    var overallScore: Double {
        let sampleScore = min(1.0, averageSamplesPerCell / 2.0)
        return (averageConfidence + coveragePercent + stabilityScore + lightingScore + tiltScore + sampleScore) / 6.0
    }

    var statusMessage: String {
        if isOptimal { return "✅ 측정 준비 완료" }

        var issues: [String] = []
        if averageConfidence <= 0.55 { issues.append("신뢰도 부족") }
        if coveragePercent <= 0.35   { issues.append("커버리지 부족") }
        if stabilityScore <= 0.25   { issues.append("기기 흔들림") }
        if lightingScore <= 0.2    { issues.append("조명 부족") }
        if tiltScore <= 0.12       { issues.append("카메라 각도 조정 필요") }
        if averageSamplesPerCell < 1.2 { issues.append("반복 관측 부족") }

        return "⚠️ " + issues.joined(separator: ", ")
    }
}
