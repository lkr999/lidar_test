import Foundation

/// 지형 분석 모듈 - slope, contour, break 분석
class TerrainAnalyzer {

    // MARK: - Slope 계산

    /// 고정밀 slope - 다중 스케일 중앙차분 (반경 3셀 = 15cm, 노이즈에 강인)
    static func calculateHighPrecisionSlope(terrain: HeightMapData, x: Int, y: Int) -> Vector2 {
        let r = 3
        let fx = max(r, min(x, terrain.gridWidth  - r - 1))
        let fy = max(r, min(y, terrain.gridHeight - r - 1))

        var gx = 0.0, gy = 0.0, wSum = 0.0
        for dr in 1...r {
            let w = 1.0 / Double(dr)
            let scale = 2.0 * Double(dr) * terrain.cellSize
            gx += w * (terrain.getHeight(x: fx + dr, y: fy) - terrain.getHeight(x: fx - dr, y: fy)) / scale
            gy += w * (terrain.getHeight(x: fx, y: fy + dr) - terrain.getHeight(x: fx, y: fy - dr)) / scale
            wSum += w
        }
        return Vector2(x: -gx / wSum, y: -gy / wSum)
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
        let stimp = max(6.0, min(14.0, 14.0 - avgRoughness * 10000.0))
        return stimp
    }

    /// Stimp → 저항(resistance) 자동 매핑
    static func stimpToResistance(stimp: Double) -> Double {
        let clamped = max(6.0, min(14.0, stimp))
        return 80.0 - (clamped - 6.0) / 8.0 * 60.0
    }

    /// 경사 크기 맵 생성 (각 그리드 포인트의 경사 크기)
    static func calculateSlopeMagnitudeMap(terrain: HeightMapData, spacing: Double = 0.30)
        -> (maxSlope: Double, slopeAtPoint: (_ gx: Int, _ gy: Int) -> Double)
    {
        var globalMax = 0.0
        let w = terrain.gridWidth, h = terrain.gridHeight

        var gy = spacing
        let tw = Double(w) * terrain.cellSize
        let th = Double(h) * terrain.cellSize
        while gy < th - 0.0001 {
            var gx = spacing
            while gx < tw - 0.0001 {
                let cx = Int(gx / terrain.cellSize)
                let cy = Int(gy / terrain.cellSize)
                let slope = calculateHighPrecisionSlope(terrain: terrain, x: cx, y: cy)
                globalMax = max(globalMax, slope.length)
                gx += spacing
            }
            gy += spacing
        }
        let maxS = max(globalMax, 0.001)

        return (maxSlope: maxS, slopeAtPoint: { gx, gy in
            let slope = calculateHighPrecisionSlope(terrain: terrain, x: gx, y: gy)
            return slope.length
        })
    }

}
