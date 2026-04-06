import Foundation
import Accelerate

/// 지형 분석 모듈 - slope, contour, break 분석, ICP 정합, 노이즈 필터링
class TerrainAnalyzer {

    // MARK: - Slope 계산

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

    /// 평균 경사도 (도 단위) - 0.5° 미만 노이즈 레벨 무시
    static func calculateAverageSlope(terrain: HeightMapData) -> Double {
        let noiseThresholdDeg = 0.5
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

    // MARK: - ICP (Iterative Closest Point) 정합

    /// 두 높이 맵의 겹치는 영역을 정렬하는 간이 ICP 정합
    /// - 새 스캔(source)을 기존 맵(target)에 최적 정합
    /// - 반환: 보정된 높이 오프셋 (ΔY), 평면 이동(ΔX, ΔZ)
    ///
    /// 원리: 겹치는 영역에서 높이 차이를 최소화하는 변환을 반복 탐색
    /// - target: 기존에 스캔된 맵 (기준)
    /// - source: 새로 스캔된 맵 (정합 대상)
    /// - maxIterations: 최대 반복 횟수 (기본 10)
    /// - Returns: (deltaX, deltaY, deltaZ) 보정 벡터
    static func alignScansICP(target: HeightMapData, source: HeightMapData,
                               maxIterations: Int = 10) -> (dx: Double, dy: Double, dz: Double) {
        var bestDx = 0.0, bestDy = 0.0, bestDz = 0.0

        // 겹치는 영역 확인: 두 그리드의 월드 좌표 범위 비교
        let targetHalfW = Double(target.gridWidth) * target.cellSize / 2.0
        let targetHalfH = Double(target.gridHeight) * target.cellSize / 2.0
        let sourceHalfW = Double(source.gridWidth) * source.cellSize / 2.0
        let sourceHalfH = Double(source.gridHeight) * source.cellSize / 2.0

        for iteration in 0..<maxIterations {
            var sumDy = 0.0
            var sumDx = 0.0
            var sumDz = 0.0
            var count = 0

            // 소스 그리드의 유효 포인트를 타겟에 매핑
            let sampleStep = max(1, min(source.gridWidth, source.gridHeight) / 50)
            for sy in stride(from: sampleStep, to: source.gridHeight - sampleStep, by: sampleStep) {
                for sx in stride(from: sampleStep, to: source.gridWidth - sampleStep, by: sampleStep) {
                    guard source.getConfidence(x: sx, y: sy) > 0.1 else { continue }

                    // 소스 포인트의 월드 좌표
                    let srcWorldX = Double(sx) * source.cellSize - sourceHalfW + source.originX + bestDx
                    let srcWorldZ = Double(sy) * source.cellSize - sourceHalfH + source.originZ + bestDz
                    let srcHeight = source.getHeight(x: sx, y: sy) + bestDy

                    // 타겟 그리드에서 대응 인덱스 찾기
                    let tgtRelX = srcWorldX - target.originX
                    let tgtRelZ = srcWorldZ - target.originZ
                    let tx = Int((tgtRelX + targetHalfW) / target.cellSize)
                    let tz = Int((tgtRelZ + targetHalfH) / target.cellSize)

                    guard tx >= 1, tx < target.gridWidth - 1,
                          tz >= 1, tz < target.gridHeight - 1,
                          target.getConfidence(x: tx, y: tz) > 0.1 else { continue }

                    let tgtHeight = target.getHeight(x: tx, y: tz)

                    // 높이 차이 및 경사 기반 평면 보정
                    let dy = tgtHeight - srcHeight
                    sumDy += dy
                    count += 1

                    // XZ 방향 기울기 기반 미세 정합
                    let tgtSlope = calculateHighPrecisionSlope(terrain: target, x: tx, y: tz)
                    if tgtSlope.length > 0.001 {
                        sumDx += dy * tgtSlope.x * 0.01
                        sumDz += dy * tgtSlope.y * 0.01
                    }
                }
            }

            guard count > 10 else { break }

            let avgDy = sumDy / Double(count)
            let avgDx = sumDx / Double(count)
            let avgDz = sumDz / Double(count)

            bestDy += avgDy * 0.5  // 감쇠 계수
            bestDx += avgDx * 0.3
            bestDz += avgDz * 0.3

            // 수렴 체크
            if abs(avgDy) < 0.0001 && abs(avgDx) < 0.0001 && abs(avgDz) < 0.0001 {
                break
            }
            _ = iteration  // suppress unused warning
        }

        return (dx: bestDx, dy: bestDy, dz: bestDz)
    }

    /// ICP 정합 결과를 소스 맵에 적용하여 타겟과 병합
    /// - 두 맵의 겹치는 영역은 신뢰도 가중 평균으로 블렌딩
    static func mergeAlignedScans(target: inout HeightMapData, source: HeightMapData,
                                   alignment: (dx: Double, dy: Double, dz: Double)) {
        let targetHalfW = Double(target.gridWidth) * target.cellSize / 2.0
        let targetHalfH = Double(target.gridHeight) * target.cellSize / 2.0
        let sourceHalfW = Double(source.gridWidth) * source.cellSize / 2.0
        let sourceHalfH = Double(source.gridHeight) * source.cellSize / 2.0

        for sy in 0..<source.gridHeight {
            for sx in 0..<source.gridWidth {
                let srcConf = source.getConfidence(x: sx, y: sy)
                guard srcConf > 0.01 else { continue }

                let srcWorldX = Double(sx) * source.cellSize - sourceHalfW + source.originX + alignment.dx
                let srcWorldZ = Double(sy) * source.cellSize - sourceHalfH + source.originZ + alignment.dz
                let srcHeight = source.getHeight(x: sx, y: sy) + alignment.dy

                let tgtRelX = srcWorldX - target.originX
                let tgtRelZ = srcWorldZ - target.originZ
                let tx = Int((tgtRelX + targetHalfW) / target.cellSize)
                let tz = Int((tgtRelZ + targetHalfH) / target.cellSize)

                guard tx >= 0, tx < target.gridWidth,
                      tz >= 0, tz < target.gridHeight else { continue }

                let tgtConf = target.getConfidence(x: tx, y: tz)
                if tgtConf < 0.01 {
                    // 타겟에 데이터 없음 → 소스 값 직접 사용
                    target.setHeight(x: tx, y: tz, value: srcHeight)
                    target.setConfidence(x: tx, y: tz, value: srcConf)
                } else {
                    // 두 값 모두 존재 → 신뢰도 가중 평균
                    let totalConf = tgtConf + srcConf
                    let blended = (target.getHeight(x: tx, y: tz) * tgtConf +
                                   srcHeight * srcConf) / totalConf
                    target.setHeight(x: tx, y: tz, value: blended)
                    target.setConfidence(x: tx, y: tz, value: min(1.0, totalConf))
                }
            }
        }
    }

    // MARK: - 고급 노이즈 필터링 (CoreML 대체)

    /// 적응형 양방향 필터 (Bilateral Filter) — 에지를 보존하면서 노이즈 제거
    /// CoreML 기반 학습 필터 대신, 통계적으로 에지를 인식하여 필터 강도를 조절
    static func applyAdaptiveBilateralFilter(_ terrain: inout HeightMapData,
                                              spatialSigma: Double = 2.0,
                                              rangeSigma: Double = 0.005) {
        let w = terrain.gridWidth, h = terrain.gridHeight
        let radius = Int(ceil(spatialSigma * 2))
        var filtered = terrain.heightMap

        for y in radius..<(h - radius) {
            for x in radius..<(w - radius) {
                guard terrain.getConfidence(x: x, y: y) > 0.01 else { continue }
                let centerH = terrain.getHeight(x: x, y: y)

                var weightedSum = 0.0
                var weightSum = 0.0

                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let nx = x + dx, ny = y + dy
                        guard terrain.getConfidence(x: nx, y: ny) > 0.01 else { continue }

                        let neighborH = terrain.getHeight(x: nx, y: ny)

                        // 공간 가중치 (가우시안)
                        let spatialDist = Double(dx * dx + dy * dy)
                        let spatialW = exp(-spatialDist / (2.0 * spatialSigma * spatialSigma))

                        // 범위 가중치 (높이 차이 기반 — 에지 보존)
                        let rangeDiff = (neighborH - centerH) * (neighborH - centerH)
                        let rangeW = exp(-rangeDiff / (2.0 * rangeSigma * rangeSigma))

                        let w = spatialW * rangeW * terrain.getConfidence(x: nx, y: ny)
                        weightedSum += neighborH * w
                        weightSum += w
                    }
                }

                if weightSum > 0 {
                    filtered[y * w + x] = weightedSum / weightSum
                }
            }
        }

        terrain.heightMap = filtered
    }

    /// 지형 거칠기 맵 생성 (각 셀 주변의 로컬 표준편차)
    /// CoreML 모델 학습 데이터 대신, 통계적 특징으로 노이즈 vs 실제 지형 구분
    static func calculateRoughnessMap(terrain: HeightMapData, radius: Int = 2) -> [Double] {
        let w = terrain.gridWidth, h = terrain.gridHeight
        var roughness = [Double](repeating: 0, count: w * h)

        for y in radius..<(h - radius) {
            for x in radius..<(w - radius) {
                guard terrain.getConfidence(x: x, y: y) > 0.01 else { continue }

                var values: [Double] = []
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        if terrain.getConfidence(x: x+dx, y: y+dy) > 0.01 {
                            values.append(terrain.getHeight(x: x+dx, y: y+dy))
                        }
                    }
                }

                guard values.count >= 3 else { continue }

                // vDSP로 평균 계산
                var mean: Double = 0
                vDSP_meanvD(values, 1, &mean, vDSP_Length(values.count))

                // 표준편차
                var variance: Double = 0
                var devs = values.map { ($0 - mean) * ($0 - mean) }
                vDSP_meanvD(&devs, 1, &variance, vDSP_Length(devs.count))

                roughness[y * w + x] = sqrt(variance)
            }
        }

        return roughness
    }
}
