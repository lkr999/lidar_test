import Foundation

/// 퍼팅 물리 엔진 - 단순 포물선(Quadratic Bezier) 모델
///
/// - 저항값 0~100%: 100% = 최대 저항 = 경사 영향 없음 (직선), 0% = 경사 영향 최대
/// - breakAmount = avgCrossSlope × distance × slopeEffect / 4
/// - slopeEffect = 1.0 - resistance/100
class PuttingPhysics {

    static let gravity: Double = 9.81
    static let baseFriction: Double = 0.065

    let terrain: HeightMapData
    let resistancePercent: Double  // 0~100

    /// 경사 영향 계수: 0(저항 100%=직선) ~ 1.0(저항 0%=최대 브레이크)
    private var slopeEffect: Double {
        1.0 - resistancePercent / 100.0
    }

    /// 유효 마찰 계수 (속도 계산용): 저항이 높을수록 더 많은 힘 필요
    private var effectiveFriction: Double {
        PuttingPhysics.baseFriction * (1.0 + resistancePercent / 100.0)
    }

    init(terrain: HeightMapData, resistancePercent: Double = 50) {
        self.terrain = terrain
        self.resistancePercent = max(0, min(100, resistancePercent))
    }

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

    /// Quadratic Bezier 궤적 생성
    private func generateBezierTrajectory(ball: Vector2, hole: Vector2,
                                           controlPt: Vector2,
                                           pointCount: Int = 40) -> [Vector2] {
        var trajectory: [Vector2] = []
        for i in 0...pointCount {
            let t = Double(i) / Double(pointCount)
            let u = 1.0 - t
            let pt = Vector2(
                x: u * u * ball.x + 2 * u * t * controlPt.x + t * t * hole.x,
                y: u * u * ball.y + 2 * u * t * controlPt.y + t * t * hole.y
            )
            trajectory.append(pt)
        }
        return trajectory
    }

    /// Break(횡이동) 계산 — 궤적의 최대 직선 이탈 거리
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

    /// 단순 포물선 모델로 최적 경로 계산
    ///
    /// - 저항 0%: 경사 영향 최대, 최소 힘
    /// - 저항 50%(기본): 중간
    /// - 저항 100%: 경사 영향 없음 (직선), 최대 힘
    func findBestSpeedAndPath(ballPos: Vector2, holePos: Vector2)
        -> (speed: Double, result: SimulationResult)
    {
        let dir = holePos - ballPos
        let distance = dir.length
        let directDir = dir.normalized()
        let perpDir = Vector2(x: -directDir.y, y: directDir.x)

        // 평균 횡경사 샘플링
        let avgCrossSlope = sampleAverageCrossSlope(from: ballPos, to: holePos)

        // 브레이크 양 = 횡경사 × 거리 × 경사영향계수 / 4
        // 저항 100% → slopeEffect=0 → breakAmount=0 (직선)
        let breakAmount = avgCrossSlope * distance * slopeEffect / 4.0

        // 컨트롤 포인트: 중간점에서 횡방향으로 오프셋
        let mid = (ballPos + holePos) * 0.5
        let controlPt = mid - perpDir * (2.0 * breakAmount)

        // Bezier 궤적 생성
        let trajectory = generateBezierTrajectory(ball: ballPos, hole: holePos,
                                                   controlPt: controlPt)

        // 에임 방향 = Bezier 시작 접선
        let aimDirection = (controlPt - ballPos).normalized()

        // 속도 = sqrt(2μgd) × 1.025 (102.5% 힘)
        // 저항이 클수록 effectiveFriction 증가 → 더 큰 힘
        let speed = sqrt(2.0 * effectiveFriction * PuttingPhysics.gravity * distance) * 1.025

        let result = SimulationResult(
            trajectory: trajectory,
            aimDirection: aimDirection,
            finalDistance: 0,
            breakAmount: calculateBreak(trajectory: trajectory, start: ballPos, end: holePos)
        )

        return (speed, result)
    }
}
