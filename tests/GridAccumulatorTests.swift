import Foundation

/// TerrainGridAccumulator 단위 테스트.
///
/// 실행: `tests/run_tests.sh` (macOS에서 swiftc로 직접 컴파일·실행, Xcode 불필요)
/// 대상: 셀 매핑(floor), 가중 평균, 불확실도, 샘플 수용 정책, 그리드 시프트, 기준선 폴백
@main
struct GridAccumulatorTests {

    static var failureCount = 0
    static var testCount = 0

    static func expect(_ condition: Bool, _ message: String,
                       file: String = #file, line: Int = #line) {
        testCount += 1
        if !condition {
            failureCount += 1
            print("❌ FAIL [\(line)] \(message)")
        }
    }

    static func expectClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9,
                            _ message: String, line: Int = #line) {
        expect(abs(a - b) <= tolerance, "\(message) (got \(a), expected \(b))", line: line)
    }

    /// 4×4 그리드, 1m 셀 → 그리드 범위 [-2, 2)
    static func makeGrid() -> TerrainGridAccumulator {
        TerrainGridAccumulator(gridWidth: 4, gridHeight: 4, cellSize: 1.0,
                               targetSamplesPerCell: 2, highConfidenceThreshold: 0.75)
    }

    // MARK: - 셀 매핑 (floor 동작)

    static func testCellMapping() {
        var g = makeGrid()

        // 그리드 중심(0,0) → 셀 (2,2) = index 10
        expect(g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 1.0),
               "중심 좌표는 수용되어야 함")
        expect(g.filledCells.contains(2 * 4 + 2), "중심 좌표는 셀 (2,2)에 매핑")

        // 왼쪽 경계 바로 안 (-2.0) → 셀 0
        expect(g.accumulate(relX: -2.0, relZ: -2.0, height: 1.0, confidence: 1.0),
               "경계 안쪽(-2.0)은 수용되어야 함")
        expect(g.filledCells.contains(0), "(-2,-2)는 셀 (0,0)에 매핑")

        // 왼쪽 경계 바로 밖 (-2.01) → 거부 (Int() 절단이었다면 셀 0으로 잘못 흡수)
        expect(!g.accumulate(relX: -2.01, relZ: 0, height: 1.0, confidence: 1.0),
               "경계 밖(-2.01)은 거부되어야 함 (floor 매핑)")

        // 오른쪽 경계 바로 밖 (+2.0) → 거부 (셀 4는 범위 밖)
        expect(!g.accumulate(relX: 2.0, relZ: 0, height: 1.0, confidence: 1.0),
               "+2.0은 그리드 범위 밖")
    }

    // MARK: - 가중 평균

    static func testWeightedAverage() {
        var g = makeGrid()

        // 같은 셀에 (높이 1.0, w=1.0), (높이 2.0, w=3.0) → 가중 평균 1.75
        g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 1.0)
        g.accumulate(relX: 0, relZ: 0, height: 2.0, confidence: 3.0)

        let maps = g.weightedHeightMap(baseline: 0)
        let idx = 2 * 4 + 2
        expectClose(maps.heights[idx], 1.75, "신뢰도 가중 평균")
        expectClose(maps.confidence[idx], 1.0, "wsum 4 / target 2 → 1.0으로 클램프")

        // baseline 차감
        let shifted = g.weightedHeightMap(baseline: 1.0)
        expectClose(shifted.heights[idx], 0.75, "baseline 차감된 평균")
    }

    // MARK: - 불확실도 (가중 표준편차)

    static func testUncertainty() {
        var g = makeGrid()

        // 동일 가중치로 높이 0.0, 2.0 → 평균 1, 분산 1, 표준편차 1
        g.accumulate(relX: 0, relZ: 0, height: 0.0, confidence: 1.0)
        g.accumulate(relX: 0, relZ: 0, height: 2.0, confidence: 1.0)

        let maps = g.weightedHeightMap(baseline: 0)
        let idx = 2 * 4 + 2
        expectClose(maps.uncertainty[idx], 1.0, "가중 표준편차")

        // 단일 샘플 → 불확실도 0
        var g2 = makeGrid()
        g2.accumulate(relX: 0, relZ: 0, height: 5.0, confidence: 1.0)
        expectClose(g2.weightedHeightMap(baseline: 0).uncertainty[idx], 0.0,
                    "단일 샘플 불확실도는 0")
    }

    // MARK: - 샘플 수용 정책 (저신뢰 상한 / 고신뢰 무제한)

    static func testSampleAcceptancePolicy() {
        var g = makeGrid()

        // 저신뢰(0.5) 샘플은 targetSamplesPerCell(2)개까지만
        expect(g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.5),
               "저신뢰 1번째 수용")
        expect(g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.5),
               "저신뢰 2번째 수용")
        expect(!g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.5),
               "저신뢰 3번째 거부")

        // 고신뢰(≥0.75) 샘플은 상한 없이 계속 수용 → 평균 정밀도 향상
        for i in 0..<20 {
            expect(g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.9),
                   "고신뢰 샘플 \(i + 1)번째 수용 (상한 없음)")
        }
        expect(g.counts[2 * 4 + 2] == 22, "셀 샘플 수 = 저신뢰 2 + 고신뢰 20")
        expectClose(g.averageSamplesPerCell, 22.0, "averageSamplesPerCell")
    }

    // MARK: - isHighConfidence 플래그 (복합 가중치가 낮아도 센서 고신뢰면 수용)

    static func testHighConfidenceFlag() {
        var g = makeGrid()

        // 저신뢰 가중치로 셀을 상한(2개)까지 채움
        g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.5)
        g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.5)
        expect(!g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 0.5),
               "플래그 없는 저신뢰 샘플은 상한 후 거부")

        // 복합 가중치는 낮지만(기울기 30° 등) 센서 신뢰도가 high인 깊이 샘플:
        // 플래그로 수용되어야 함 — 미수용 시 그리드가 비어 평면 인식 버그 발생
        expect(g.accumulate(relX: 0, relZ: 0, height: 1.0,
                            confidence: 0.5, isHighConfidence: true),
               "센서 고신뢰 샘플은 가중치가 낮아도 상한 없이 수용")
        expect(g.counts[2 * 4 + 2] == 3, "플래그 수용 후 샘플 수 3")
    }

    // MARK: - 그리드 시프트 (패닝)

    static func testShift() {
        var g = makeGrid()

        // 셀 (2,2)에 샘플 (relX 0, relZ 0)
        g.accumulate(relX: 0, relZ: 0, height: 3.0, confidence: 1.0)

        // 카메라가 +X로 1셀 이동 → shift(dxCells: 1): 데이터는 (1,2)로 이동해야 함
        g.shift(dxCells: 1, dzCells: 0)

        let movedIdx = 2 * 4 + 1
        expect(g.filledCells.contains(movedIdx), "시프트 후 셀 (1,2)에 데이터 존재")
        expect(g.filledCells.count == 1, "시프트 후 채워진 셀은 1개")
        expect(g.totalSamples == 1, "totalSamples 보존")
        expectClose(g.weightedHeightMap(baseline: 0).heights[movedIdx], 3.0,
                    "시프트 후 높이 값 보존")
        expect(g.minX == 1 && g.maxX == 1 && g.minZ == 2 && g.maxZ == 2,
               "시프트 후 바운딩 박스 재계산")

        // 범위 밖으로 밀려나는 시프트 → 데이터 소실, 상태 일관성 유지
        g.shift(dxCells: 10, dzCells: 0)
        expect(g.filledCells.isEmpty && g.totalSamples == 0,
               "범위 밖 시프트 후 빈 상태")
    }

    // MARK: - 기준선 폴백 (지면 미감지 시 최저 평균 높이)

    static func testMinAverageHeight() {
        var g = makeGrid()
        expect(g.minAverageHeight() == nil, "빈 그리드는 nil")

        g.accumulate(relX: 0,   relZ: 0, height: 2.0, confidence: 1.0)
        g.accumulate(relX: 1.0, relZ: 0, height: 0.5, confidence: 1.0)
        g.accumulate(relX: 0, relZ: 1.0, height: 1.2, confidence: 1.0)
        expectClose(g.minAverageHeight() ?? .nan, 0.5, "유효 셀 평균 높이의 최솟값")
    }

    // MARK: - reset

    static func testReset() {
        var g = makeGrid()
        g.accumulate(relX: 0, relZ: 0, height: 1.0, confidence: 1.0)
        g.reset()
        expect(g.filledCells.isEmpty && g.totalSamples == 0 && !g.bboxInitialized,
               "reset 후 빈 상태")
        expect(g.weightedHeights.allSatisfy { $0 == 0 }, "reset 후 누적 버퍼 0")
    }

    // MARK: - Main

    static func main() {
        testCellMapping()
        testWeightedAverage()
        testUncertainty()
        testSampleAcceptancePolicy()
        testHighConfidenceFlag()
        testShift()
        testMinAverageHeight()
        testReset()

        if failureCount == 0 {
            print("✅ \(testCount)개 검증 모두 통과")
        } else {
            print("❌ \(failureCount)/\(testCount)개 실패")
            exit(1)
        }
    }
}
