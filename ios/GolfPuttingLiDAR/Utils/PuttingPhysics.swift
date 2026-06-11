import Foundation

/// 퍼팅 물리 엔진 - 경사/마찰 기반 2D 수치 시뮬레이션
///
/// 여러 에임 각도와 초기 속도를 탐색한 뒤 컵 근접 오차가 가장 낮은 경로를 선택합니다.
/// 저항값은 마찰 증가와 경사 영향 감소를 동시에 표현합니다.
class PuttingPhysics {

    static let gravity: Double = 9.81
    static let baseFriction: Double = 0.065

    private let cupRadius: Double = 0.054
    private let maxCupEntrySpeed: Double = 1.35
    private let timeStep: Double = 0.025
    private let maxSimulationTime: Double = 8.0

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

    // MARK: - Main Search

    func findBestSpeedAndPath(ballPos: Vector2, holePos: Vector2)
        -> (speed: Double, result: SimulationResult)
    {
        let toHole = holePos - ballPos
        let distance = toHole.length
        guard distance > 0.01 else {
            return (0, SimulationResult(
                trajectory: [ballPos, holePos],
                aimDirection: .zero,
                finalDistance: 0,
                breakAmount: 0
            ))
        }

        let directDir = toHole.normalized()
        let baseSpeed = estimateLaunchSpeed(from: ballPos, to: holePos)
        let angleLimit = slopeEffect < 0.001 ? 0 : min(.pi / 3.0, 0.14 + slopeEffect * 0.55)
        let angleSteps = angleLimit == 0 ? 0 : 18
        let speedSteps = 22

        var best: (score: Double, speed: Double, result: SimulationResult)?

        for ai in (-angleSteps)...angleSteps {
            let angle = angleSteps == 0 ? 0 : angleLimit * Double(ai) / Double(angleSteps)
            let aimDir = rotate(directDir, by: angle).normalized()

            for si in 0..<speedSteps {
                let multiplier = 0.72 + Double(si) * 0.045
                let speed = baseSpeed * multiplier
                let candidate = simulate(ballPos: ballPos, holePos: holePos, aimDir: aimDir, speed: speed)

                if best == nil || candidate.score < best!.score {
                    best = (candidate.score, speed, candidate.result)
                }
            }
        }

        guard let best else {
            let fallbackSpeed = estimateLaunchSpeed(from: ballPos, to: holePos)
            return (fallbackSpeed, SimulationResult(
                trajectory: [ballPos, holePos],
                aimDirection: directDir,
                finalDistance: distance,
                breakAmount: 0
            ))
        }

        return (best.speed, best.result)
    }

    // MARK: - Simulation

    private func simulate(ballPos: Vector2, holePos: Vector2, aimDir: Vector2, speed: Double)
        -> (score: Double, result: SimulationResult)
    {
        let directDistance = (holePos - ballPos).length
        let maxSteps = Int(maxSimulationTime / timeStep)
        var position = ballPos
        var velocity = aimDir * speed
        var points: [Vector2] = [ballPos]
        points.reserveCapacity(160)

        var closestDistance = directDistance
        var entrySpeed = speed
        var reachedCup = false

        for step in 0..<maxSteps {
            let speedNow = velocity.length
            if speedNow < 0.025 { break }

            let previous = position
            let slope = terrainSlope(at: position)
            let slopeAcceleration = slope * (PuttingPhysics.gravity * slopeEffect)
            let frictionAcceleration = velocity.normalized() * (-effectiveFriction * PuttingPhysics.gravity)
            let acceleration = slopeAcceleration + frictionAcceleration

            velocity = velocity + acceleration * timeStep
            position = position + velocity * timeStep

            let distanceToCup = (position - holePos).length
            if distanceToCup < closestDistance {
                closestDistance = distanceToCup
                entrySpeed = velocity.length
            }

            if segmentDistance(from: previous, to: position, point: holePos) <= cupRadius {
                entrySpeed = velocity.length
                closestDistance = 0
                reachedCup = entrySpeed <= maxCupEntrySpeed
                if reachedCup {
                    points.append(holePos)
                    break
                }
            }

            if step % 2 == 0 {
                points.append(position)
            }

            if !terrain.containsLocal(position) && (position - ballPos).length > directDistance * 1.2 {
                break
            }
        }

        if points.last.map({ ($0 - position).length > 0.001 }) ?? true {
            points.append(position)
        }

        let trajectory = downsample(points, maxCount: 64)
        let breakAmount = calculateBreak(trajectory: trajectory, start: ballPos, end: holePos)
        let endDistance = (position - holePos).length
        let speedPenalty = max(0, entrySpeed - maxCupEntrySpeed) * 0.08
        let missPenalty = reachedCup ? 0 : min(endDistance, directDistance) * 0.18
        let score = closestDistance + speedPenalty + missPenalty + breakAmount * 0.01

        return (score, SimulationResult(
            trajectory: trajectory,
            aimDirection: aimDir,
            finalDistance: closestDistance,
            breakAmount: breakAmount
        ))
    }

    // MARK: - Relative Power (평지 기준 상대 세기)

    /// 평지(높이차 0)·중간 저항(50%)에서 같은 거리를 보내는 데 필요한
    /// 운동에너지를 100으로 두고, 실제 추천 속도의 운동에너지를 비례 수치로 환산.
    /// 오르막·고저항이면 100보다 커지고, 내리막·저저항이면 작아진다.
    func relativePowerPercent(speed: Double, ballPos: Vector2, holePos: Vector2) -> Double {
        let distance = max(0.01, (holePos - ballPos).length)
        // 기준: 평지 + 저항 50% (중립 그린)에서의 필요 속도² = 2·μ기준·g·d
        let referenceFriction = PuttingPhysics.baseFriction * 1.5
        let flatSpeedSquared = 2.0 * referenceFriction * PuttingPhysics.gravity * distance
        guard flatSpeedSquared > 1e-9 else { return 100 }
        let power = 100.0 * (speed * speed) / flatSpeedSquared
        return max(1, min(999, power))
    }

    private func estimateLaunchSpeed(from ball: Vector2, to hole: Vector2) -> Double {
        let distance = max(0.01, (hole - ball).length)
        let ballH = terrainHeight(at: ball)
        let holeH = terrainHeight(at: hole)
        let heightDelta = holeH - ballH
        let workPerMass = effectiveFriction * PuttingPhysics.gravity * distance
                        + PuttingPhysics.gravity * heightDelta
        let speed = sqrt(max(0.04, 2.0 * workPerMass))
        return max(0.25, min(speed * 1.08, 4.0))
    }

    private func terrainSlope(at position: Vector2) -> Vector2 {
        guard terrain.containsLocal(position) else { return .zero }
        let gx = Int(position.x / terrain.cellSize)
        let gy = Int(position.y / terrain.cellSize)
        return TerrainAnalyzer.calculateHighPrecisionSlope(terrain: terrain, x: gx, y: gy)
    }

    private func terrainHeight(at position: Vector2) -> Double {
        let gx = Int(position.x / terrain.cellSize)
        let gy = Int(position.y / terrain.cellSize)
        return terrain.getHeight(x: gx, y: gy)
    }

    // MARK: - Geometry Helpers

    private func rotate(_ vector: Vector2, by angle: Double) -> Vector2 {
        let c = cos(angle)
        let s = sin(angle)
        return Vector2(
            x: vector.x * c - vector.y * s,
            y: vector.x * s + vector.y * c
        )
    }

    private func segmentDistance(from a: Vector2, to b: Vector2, point p: Vector2) -> Double {
        let ab = b - a
        let abLen2 = ab.dot(ab)
        guard abLen2 > 1e-9 else { return (p - a).length }
        let t = max(0, min(1, (p - a).dot(ab) / abLen2))
        let projection = a + ab * t
        return (p - projection).length
    }

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

    private func downsample(_ points: [Vector2], maxCount: Int) -> [Vector2] {
        guard points.count > maxCount, maxCount >= 2 else { return points }
        var sampled: [Vector2] = []
        sampled.reserveCapacity(maxCount)
        for i in 0..<maxCount {
            let sourceIndex = Int(round(Double(i) * Double(points.count - 1) / Double(maxCount - 1)))
            sampled.append(points[min(points.count - 1, sourceIndex)])
        }
        return sampled
    }
}
