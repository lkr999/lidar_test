import Foundation
import simd

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

    /// 스캔 시 평균 pitch 각도 (도). 카메라가 수직 아래를 향하면 ≈ -90°
    var tiltPitch: Double = 0
    /// 스캔 시 평균 roll 각도 (도). 수평이면 ≈ 0°
    var tiltRoll: Double = 0
    /// 스캔에 기여한 총 포인트 수 (품질 참고용)
    var totalPointCount: Int = 0
    /// 그리드 월드 좌표 원점 X (mapToGrid 상대좌표 기준)
    var originX: Double = 0
    /// 그리드 월드 좌표 원점 Z (mapToGrid 상대좌표 기준)
    var originZ: Double = 0

    var minHeight: Double {
        heightMap.min() ?? 0
    }
    
    var maxHeight: Double {
        heightMap.max() ?? 0
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
    
    /// 가우시안 스무딩 적용
    mutating func applyGaussianSmoothing(kernelSize: Int = 3) {
        let sigma = Double(kernelSize) / 3.0
        var kernel: [[Double]] = Array(
            repeating: Array(repeating: 0, count: kernelSize),
            count: kernelSize
        )
        var kernelSum: Double = 0
        let half = kernelSize / 2
        
        for ky in 0..<kernelSize {
            for kx in 0..<kernelSize {
                let dx = Double(kx - half)
                let dy = Double(ky - half)
                let value = exp(-(dx*dx + dy*dy) / (2 * sigma * sigma))
                kernel[ky][kx] = value
                kernelSum += value
            }
        }
        
        // Normalize kernel
        for ky in 0..<kernelSize {
            for kx in 0..<kernelSize {
                kernel[ky][kx] /= kernelSum
            }
        }
        
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
    /// 카메라가 바닥을 향하는 정도 (0=수평, 1=수직 아래) — 자이로 기반
    var tiltScore: Double = 0

    var isOptimal: Bool {
        averageConfidence > 0.7 &&
        coveragePercent > 0.8 &&
        stabilityScore > 0.6 &&
        lightingScore > 0.5 &&
        tiltScore > 0.25          // 카메라가 최소 14° 이상 아래를 향해야 함
    }

    var overallScore: Double {
        // tiltScore 포함 5개 지표 평균
        (averageConfidence + coveragePercent + stabilityScore + lightingScore + tiltScore) / 5.0
    }

    var statusMessage: String {
        if isOptimal { return "✅ 측정 준비 완료" }

        var issues: [String] = []
        if averageConfidence <= 0.7 { issues.append("신뢰도 부족") }
        if coveragePercent <= 0.8   { issues.append("커버리지 부족") }
        if stabilityScore <= 0.6   { issues.append("기기 흔들림") }
        if lightingScore <= 0.5    { issues.append("조명 부족") }
        if tiltScore <= 0.25       { issues.append("카메라 각도 조정 필요") }

        return "⚠️ " + issues.joined(separator: ", ")
    }
}
