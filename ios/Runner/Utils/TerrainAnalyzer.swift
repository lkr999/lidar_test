import Foundation

/// 지형 분석 모듈 - slope, contour, break 분석
class TerrainAnalyzer {
    
    /// Central Difference로 slope 벡터 계산
    static func calculateSlope(terrain: HeightMapData, x: Int, y: Int) -> Vector2 {
        let fx = max(1, min(x, terrain.gridWidth - 2))
        let fy = max(1, min(y, terrain.gridHeight - 2))
        
        let hRight = terrain.getHeight(x: fx + 1, y: fy)
        let hLeft = terrain.getHeight(x: fx - 1, y: fy)
        let hUp = terrain.getHeight(x: fx, y: fy + 1)
        let hDown = terrain.getHeight(x: fx, y: fy - 1)
        
        let slopeX = (hRight - hLeft) / (2.0 * terrain.cellSize)
        let slopeY = (hUp - hDown) / (2.0 * terrain.cellSize)
        
        return Vector2(x: -slopeX, y: -slopeY)
    }
    
    /// 고정밀 slope - 다중 스케일 중앙차분 (반경 3셀 = 3cm, 노이즈에 강인)
    static func calculateHighPrecisionSlope(terrain: HeightMapData, x: Int, y: Int) -> Vector2 {
        let r = 3  // 3cm 반경 사용 (기존 1cm보다 노이즈 억제력 향상)
        let fx = max(r, min(x, terrain.gridWidth  - r - 1))
        let fy = max(r, min(y, terrain.gridHeight - r - 1))

        // 다중 스케일 가중 평균: 가까운 거리에 더 높은 가중치
        var gx = 0.0, gy = 0.0, wSum = 0.0
        for dr in 1...r {
            let w = 1.0 / Double(dr)          // 거리 반비례 가중치
            let scale = 2.0 * Double(dr) * terrain.cellSize
            gx += w * (terrain.getHeight(x: fx + dr, y: fy) - terrain.getHeight(x: fx - dr, y: fy)) / scale
            gy += w * (terrain.getHeight(x: fx, y: fy + dr) - terrain.getHeight(x: fx, y: fy - dr)) / scale
            wSum += w
        }
        return Vector2(x: -gx / wSum, y: -gy / wSum)
    }
    
    /// 평균 경사도 (도 단위) - 0.5° 미만 노이즈 레벨 무시
    static func calculateAverageSlope(terrain: HeightMapData) -> Double {
        let noiseThresholdDeg = 0.5  // LiDAR 노이즈로 인한 허위 경사 필터
        var totalSlope = 0.0
        var count = 0

        for y in stride(from: 3, to: terrain.gridHeight - 3, by: 3) {
            for x in stride(from: 3, to: terrain.gridWidth - 3, by: 3) {
                let slope = calculateHighPrecisionSlope(terrain: terrain, x: x, y: y)
                let angleDeg = atan(slope.length) * 180.0 / .pi
                if angleDeg > noiseThresholdDeg {
                    totalSlope += angleDeg
                    count += 1
                }
            }
        }

        return count > 0 ? totalSlope / Double(count) : 0
    }
    
    /// 최대 경사 방향
    static func dominantSlopeDirection(terrain: HeightMapData) -> Vector2 {
        var totalSlope = Vector2.zero
        var count = 0
        
        for y in stride(from: 2, to: terrain.gridHeight - 2, by: 5) {
            for x in stride(from: 2, to: terrain.gridWidth - 2, by: 5) {
                let slope = calculateHighPrecisionSlope(terrain: terrain, x: x, y: y)
                totalSlope = totalSlope + slope
                count += 1
            }
        }
        
        return count > 0 ? (totalSlope / Double(count)).normalized() : .zero
    }
    
    /// 높이 범위 (cm 단위)
    static func heightRange(terrain: HeightMapData) -> Double {
        return (terrain.maxHeight - terrain.minHeight) * 100.0
    }
    
    /// Stimp Speed 추정 (경사 매끄러움 기반)
    static func estimateStimpSpeed(terrain: HeightMapData) -> Double {
        var roughness = 0.0
        var count = 0
        
        for y in 1..<(terrain.gridHeight - 1) {
            for x in 1..<(terrain.gridWidth - 1) {
                let h = terrain.getHeight(x: x, y: y)
                let avg = (
                    terrain.getHeight(x: x-1, y: y) +
                    terrain.getHeight(x: x+1, y: y) +
                    terrain.getHeight(x: x, y: y-1) +
                    terrain.getHeight(x: x, y: y+1)
                ) / 4.0
                
                roughness += abs(h - avg)
                count += 1
            }
        }
        
        let avgRoughness = count > 0 ? roughness / Double(count) : 0.001
        // Stimp = 약 8~14, 매끄러울수록 높음
        let stimp = max(6.0, min(14.0, 14.0 - avgRoughness * 10000.0))
        return stimp
    }
}
