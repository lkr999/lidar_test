import Foundation

/// 퍼팅 물리 엔진 - Quadratic Bezier 포물선 모델
///
/// 볼에서 홀까지 충분한 힘이 가해진다고 가정하며,
/// 경사에 의한 횡방향 브레이크를 반영한 단순 포물선 경로를 생성합니다.
///
/// - 저항 0%  : slopeEffect = 1.0 → 경사 영향 최대 (최대 브레이크)
/// - 저항 100%: slopeEffect = 0.0 → 경사 영향 없음 (직선)
class PuttingPhysics {

    static let gravity: Double = 9.81
    static let baseFriction: Double = 0.065

    let terrain: HeightMapData
    let resistancePercent: Double  // 0~100

    /// 경사 영향 계수: 저항 0% → 1.0(최대), 저항 100% → 0.0(경사 무시)
    private var slopeEffect: Double {
        1.0 - resistancePercent / 100.0
    }

    /// 유효 마찰 계수: 저항이 높을수록 더 많은 힘 필요
    private var effectiveFriction: Double {
        PuttingPhysics.baseFriction * (1.0 + resistancePercent / 100.0)
    }

    init(terrain: HeightMapData, resistancePercent: Double = 50) {
        self.terrain = terrain
        self.resistancePercent = max(0, min(100, resistancePercent))
    }

    // MARK: - 횡경사 샘플링

    /// 볼→홀 경로를 따라 평균 횡경사(cross-slope) 샘플링
    private func sampleAverageCrossSlope(from ball: Vector2, to hole: Vector2) -> Double {
        let dir = hole - ball
        let dist = dir.length
        guard dist > 0.01 else { return 0 }
        let directDir = dir.normalized()
        let perpDir = Vector2(x: -directDir.y, y: directDir.x)

        let sampleCount = max(5, Int(dist / 0.05))
        var crossSlopeSum: Double = 0
        var validSamples = 0

        for i in 0...sampleCount {
            let t = Double(i) / Double(sampleCount)
            let pos = ball + dir * t
            let gx = Int(pos.x / terrain.cellSize)
            let gy = Int(pos.y / terrain.cellSize)
            guard gx >= 0, gx < terrain.gridWidth,
                  gy >= 0, gy < terrain.gridHeight else { continue }
            let slope = TerrainAnalyzer.calculateHighPrecisionSlope(terrain: terrain, x: gx, y: gy)
            crossSlopeSum += slope.dot(perpDir)
            validSamples += 1
        }

        guard validSamples > 0 else { return 0 }
        return crossSlopeSum / Double(validSamples)
    }

    // MARK: - Bezier 생성

    /// Quadratic Bezier 포물선 궤적 생성 (40점)
    private func generateBezier(ball: Vector2, hole: Vector2,
                                  control: Vector2, pointCount: Int = 40) -> [Vector2] {
        var pts: [Vector2] = []
        for i in 0...pointCount {
            let t = Double(i) / Double(pointCount)
            let u = 1.0 - t
            pts.append(Vector2(
                x: u*u*ball.x + 2*u*t*control.x + t*t*hole.x,
                y: u*u*ball.y + 2*u*t*control.y + t*t*hole.y
            ))
        }
        return pts
    }

    // MARK: - Break 계산

    private func calculateBreak(trajectory: [Vector2], start: Vector2, end: Vector2) -> Double {
        guard trajectory.count >= 3 else { return 0 }
        let directLine = (end - start).normalized()
        var maxPerp = 0.0
        for pt in trajectory {
            let toPoint = pt - start
            let projLen = toPoint.dot(directLine)
            let proj = directLine * projLen
            let perpDist = (toPoint - proj).length
            maxPerp = max(maxPerp, perpDist)
        }
        return maxPerp
    }

    // MARK: - 메인 함수

    /// Bezier 포물선으로 최적 경로와 에임 방향 계산
    ///
    /// 충분한 힘이 가해진다고 가정 → 볼이 감속 없이 홀까지 호를 그리며 도달
    ///
    /// - 저항 0%  : 경사 브레이크 최대, 에임이 크게 옆으로 향함
    /// - 저항 100%: 직선 경로
    func findBestSpeedAndPath(ballPos: Vector2, holePos: Vector2)
        -> (speed: Double, result: SimulationResult)
    {
        let dir = holePos - ballPos
        let distance = dir.length
        let directDir = dir.normalized()
        let perpDir = Vector2(x: -directDir.y, y: directDir.x)

        // 초기 속도 계산 (유효 마찰 기반)
        let speed = sqrt(2.0 * effectiveFriction * PuttingPhysics.gravity * distance) * 1.025

        // 저항 100%: 직선
        if slopeEffect < 0.001 {
            return (speed, SimulationResult(
                trajectory: [ballPos, holePos],
                aimDirection: directDir,
                finalDistance: 0,
                breakAmount: 0
            ))
        }

        // 평균 횡경사 샘플링
        let avgCrossSlope = sampleAverageCrossSlope(from: ballPos, to: holePos)

        // 브레이크 = 횡경사 × 거리 × 경사영향계수
        // 저항 0% → 최대, 저항 100% → 0
        let breakAmount = avgCrossSlope * distance * slopeEffect

        // Bezier 컨트롤 포인트: 중점에서 횡방향으로 오프셋
        // (2× 곱하면 최대 편차 = breakAmount)
        let mid = (ballPos + holePos) * 0.5
        let controlPt = mid - perpDir * (2.0 * breakAmount)

        // 단순 포물선 궤적 생성
        let trajectory = generateBezier(ball: ballPos, hole: holePos, control: controlPt)

        // 에임 방향 = Bezier 시작 접선 (ballPos → controlPt 방향)
        let aimDirection = (controlPt - ballPos).normalized()

        let breakAmt = calculateBreak(trajectory: trajectory, start: ballPos, end: holePos)

        return (speed, SimulationResult(
            trajectory: trajectory,
            aimDirection: aimDirection,
            finalDistance: 0,
            breakAmount: breakAmt
        ))
    }
}
