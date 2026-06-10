import Foundation

/// LiDAR 스캔 높이 누적 그리드 — 셀별 신뢰도 가중 평균/분산 계산 순수 로직.
///
/// ARKit 의존성이 없어 macOS에서도 컴파일되며 단위 테스트가 가능하다
/// (`tests/run_tests.sh` 참조). `LiDARScanner`는 월드→그리드 상대 좌표 변환 후
/// 이 타입에 샘플 누적·시프트·평균화를 위임한다.
///
/// 샘플 수용 정책:
/// - 고신뢰(`highConfidenceThreshold` 이상) 샘플은 상한 없이 계속 평균에 기여
///   (셀당 누적이 O(1)이므로 비용 증가 없음, 반복 관측이 많을수록 노이즈 감소)
/// - 저신뢰 샘플은 셀당 `targetSamplesPerCell`개까지만 허용해 평균 오염 방지
struct TerrainGridAccumulator {

    // MARK: - Configuration

    let gridWidth: Int
    let gridHeight: Int
    let cellSize: Double
    /// 저신뢰 샘플의 셀당 허용 개수
    let targetSamplesPerCell: Int
    /// 이 값 이상의 신뢰도 샘플은 개수 상한 없이 누적
    let highConfidenceThreshold: Double

    // MARK: - Accumulated State (index = z * gridWidth + x)

    /// Σ(신뢰도 × 높이)
    private(set) var weightedHeights: [Double]
    /// Σ(신뢰도 × 높이²) — 가중 분산 계산용
    private(set) var weightedHeightSquares: [Double]
    /// 셀별 샘플 개수
    private(set) var counts: [Int]
    /// Σ신뢰도
    private(set) var confidenceSums: [Double]
    /// 샘플이 1개 이상인 셀 인덱스 (빠른 스파스 반복용)
    private(set) var filledCells = Set<Int>()
    private(set) var totalSamples = 0

    // 채워진 셀 바운딩 박스
    private(set) var minX = 0
    private(set) var maxX = 0
    private(set) var minZ = 0
    private(set) var maxZ = 0
    private(set) var bboxInitialized = false

    var filledCellCount: Int { filledCells.count }

    var averageSamplesPerCell: Double {
        filledCells.isEmpty ? 0 : Double(totalSamples) / Double(filledCells.count)
    }

    // MARK: - Init / Reset

    init(gridWidth: Int, gridHeight: Int, cellSize: Double,
         targetSamplesPerCell: Int = 2, highConfidenceThreshold: Double = 0.75) {
        self.gridWidth  = gridWidth
        self.gridHeight = gridHeight
        self.cellSize   = cellSize
        self.targetSamplesPerCell    = targetSamplesPerCell
        self.highConfidenceThreshold = highConfidenceThreshold

        let totalCells = gridWidth * gridHeight
        weightedHeights       = Array(repeating: 0.0, count: totalCells)
        weightedHeightSquares = Array(repeating: 0.0, count: totalCells)
        counts                = Array(repeating: 0,   count: totalCells)
        confidenceSums        = Array(repeating: 0.0, count: totalCells)
    }

    mutating func reset() {
        let totalCells = gridWidth * gridHeight
        weightedHeights       = Array(repeating: 0.0, count: totalCells)
        weightedHeightSquares = Array(repeating: 0.0, count: totalCells)
        counts                = Array(repeating: 0,   count: totalCells)
        confidenceSums        = Array(repeating: 0.0, count: totalCells)
        filledCells.removeAll()
        totalSamples = 0
        minX = 0; maxX = 0; minZ = 0; maxZ = 0
        bboxInitialized = false
    }

    // MARK: - Accumulate

    /// 그리드 중심 기준 상대 좌표(relX, relZ)의 높이 샘플을 누적.
    /// - Parameters:
    ///   - confidence: 평균에 사용되는 가중치 (센서 신뢰도 × 기울기 × 거리감쇠 등 복합값)
    ///   - isHighConfidence: 센서 자체 신뢰도가 높은 샘플임을 명시.
    ///     복합 가중치는 기울기·거리 항 때문에 낮아질 수 있으므로, 수용 정책은
    ///     이 플래그(또는 confidence ≥ threshold)로 판단해 깊이 샘플 기아를 방지한다.
    /// - Returns: 그리드에 기여했으면 true
    @discardableResult
    mutating func accumulate(relX: Double, relZ: Double,
                             height: Double, confidence: Double,
                             isHighConfidence: Bool = false) -> Bool {
        let halfX = Double(gridWidth)  * cellSize / 2.0
        let halfZ = Double(gridHeight) * cellSize / 2.0

        // floor 사용: Int() 절단은 -1~0 구간을 0번 셀로 잘못 흡수한다
        let gx = Int(((relX + halfX) / cellSize).rounded(.down))
        let gz = Int(((relZ + halfZ) / cellSize).rounded(.down))

        guard gx >= 0, gx < gridWidth, gz >= 0, gz < gridHeight else { return false }

        let idx = gz * gridWidth + gx

        // 저신뢰 샘플은 목표 샘플 수까지만 — 고신뢰 샘플은 상한 없이 평균 정밀도 향상
        let highConfidence = isHighConfidence || confidence >= highConfidenceThreshold
        if !highConfidence && counts[idx] >= targetSamplesPerCell {
            return false
        }

        if counts[idx] == 0 {
            filledCells.insert(idx)
            if !bboxInitialized {
                minX = gx; maxX = gx
                minZ = gz; maxZ = gz
                bboxInitialized = true
            } else {
                if gx < minX { minX = gx }
                if gx > maxX { maxX = gx }
                if gz < minZ { minZ = gz }
                if gz > maxZ { maxZ = gz }
            }
        }

        weightedHeights[idx]       += height * confidence
        weightedHeightSquares[idx] += height * height * confidence
        confidenceSums[idx]        += confidence
        counts[idx]                += 1
        totalSamples += 1
        return true
    }

    // MARK: - Shift (그리드 패닝)

    /// 그리드 데이터를 (dxCells, dzCells) 셀만큼 시프트.
    /// 기존 데이터는 유지되고 범위를 벗어나는 셀은 버려지며 새 영역은 빈 상태가 된다.
    mutating func shift(dxCells: Int, dzCells: Int) {
        guard dxCells != 0 || dzCells != 0 else { return }

        let w = gridWidth, h = gridHeight
        var newHeights       = Array(repeating: 0.0, count: w * h)
        var newHeightSquares = Array(repeating: 0.0, count: w * h)
        var newCounts        = Array(repeating: 0,   count: w * h)
        var newConfidence    = Array(repeating: 0.0, count: w * h)
        var newFilled = Set<Int>()
        var newTotal = 0

        for z in 0..<h {
            let srcZ = z + dzCells
            guard srcZ >= 0, srcZ < h else { continue }
            for x in 0..<w {
                let srcX = x + dxCells
                guard srcX >= 0, srcX < w else { continue }
                let srcIdx = srcZ * w + srcX
                guard counts[srcIdx] > 0 else { continue }
                let dstIdx = z * w + x
                newHeights[dstIdx]       = weightedHeights[srcIdx]
                newHeightSquares[dstIdx] = weightedHeightSquares[srcIdx]
                newCounts[dstIdx]        = counts[srcIdx]
                newConfidence[dstIdx]    = confidenceSums[srcIdx]
                newFilled.insert(dstIdx)
                newTotal += counts[srcIdx]
            }
        }

        weightedHeights       = newHeights
        weightedHeightSquares = newHeightSquares
        counts                = newCounts
        confidenceSums        = newConfidence
        filledCells           = newFilled
        totalSamples          = newTotal
        recalculateBBox()
    }

    private mutating func recalculateBBox() {
        bboxInitialized = false
        for idx in filledCells {
            let z = idx / gridWidth
            let x = idx % gridWidth
            if !bboxInitialized {
                minX = x; maxX = x
                minZ = z; maxZ = z
                bboxInitialized = true
            } else {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if z < minZ { minZ = z }
                if z > maxZ { maxZ = z }
            }
        }
    }

    // MARK: - Weighted Averages

    /// 신뢰도 가중 평균 높이맵(baseline 차감) + 셀 신뢰도 + 불확실도(가중 표준편차)
    func weightedHeightMap(baseline: Double)
        -> (heights: [Double], confidence: [Double], uncertainty: [Double])
    {
        let totalCells = gridWidth * gridHeight
        var heightFlat      = [Double](repeating: 0, count: totalCells)
        var confFlat        = [Double](repeating: 0, count: totalCells)
        var uncertaintyFlat = [Double](repeating: 0, count: totalCells)

        for idx in filledCells {
            let wsum = confidenceSums[idx]
            guard wsum > 0 else { continue }
            let avg = weightedHeights[idx] / wsum
            heightFlat[idx] = avg - baseline
            confFlat[idx]   = min(1.0, wsum / Double(targetSamplesPerCell))
            let variance = max(0, weightedHeightSquares[idx] / wsum - avg * avg)
            uncertaintyFlat[idx] = variance.squareRoot()
        }

        return (heightFlat, confFlat, uncertaintyFlat)
    }

    /// 유효 셀들의 가중 평균 높이 중 최솟값 (지면 기준선 폴백용)
    func minAverageHeight() -> Double? {
        var minH = Double.greatestFiniteMagnitude
        var found = false
        for idx in filledCells {
            let wsum = confidenceSums[idx]
            guard wsum > 0 else { continue }
            minH = min(minH, weightedHeights[idx] / wsum)
            found = true
        }
        return found ? minH : nil
    }
}
