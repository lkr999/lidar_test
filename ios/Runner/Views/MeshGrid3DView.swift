import UIKit
import SceneKit

/// SceneKit 기반 3D 인터랙티브 메쉬그리드 뷰어
///
/// - 높이 맵 데이터로부터 3D 메쉬 생성
/// - 높이별 색상 매핑 (초록→노랑→빨강)
/// - 핀치 줌, 팬, 회전 제스처로 자유 시점 탐색
/// - 등고선, 물 흐름 화살표 3D 표시
/// - 퍼팅 궤적 3D 표시
@available(iOS 14.0, *)
class MeshGrid3DView: UIView {

    // MARK: - Properties

    private let scnView: SCNView
    private let scene = SCNScene()
    private var meshNode: SCNNode?
    private var contourNode: SCNNode?
    private var trajectoryNode: SCNNode?
    private var arrowNodes: [SCNNode] = []
    private var terrain: HeightMapData?

    // 높이 스케일 팩터 (미세한 높이 차이를 시각적으로 강조)
    private let heightScale: Float = 50.0

    // MARK: - Init

    override init(frame: CGRect) {
        scnView = SCNView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        setupSceneView()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scnView.frame = bounds
    }

    // MARK: - Setup

    private func setupSceneView() {
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.scene = scene
        scnView.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 1)
        scnView.allowsCameraControl = true   // 핀치 줌, 팬, 회전 자동 지원
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        addSubview(scnView)

        setupCamera()
        setupLighting()
    }

    private func setupCamera() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100
        cameraNode.camera?.fieldOfView = 55
        // 초기 카메라 위치: 45° 각도에서 내려다보기
        cameraNode.position = SCNVector3(0, 5, 8)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
    }

    private func setupLighting() {
        // 주 조명 (방향광)
        let mainLight = SCNNode()
        mainLight.light = SCNLight()
        mainLight.light?.type = .directional
        mainLight.light?.intensity = 800
        mainLight.light?.color = UIColor.white
        mainLight.light?.castsShadow = true
        mainLight.position = SCNVector3(5, 10, 5)
        mainLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(mainLight)

        // 보조 조명 (환경광)
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 400
        ambientLight.light?.color = UIColor(white: 0.7, alpha: 1)
        scene.rootNode.addChildNode(ambientLight)
    }

    // MARK: - Configure

    /// 높이 맵 데이터로 3D 메쉬 생성
    func configure(terrain: HeightMapData) {
        self.terrain = terrain

        // 기존 노드 제거
        meshNode?.removeFromParentNode()
        contourNode?.removeFromParentNode()
        trajectoryNode?.removeFromParentNode()
        arrowNodes.forEach { $0.removeFromParentNode() }
        arrowNodes.removeAll()

        // 메쉬 생성
        let step = adaptiveStep(for: terrain)
        meshNode = createMeshNode(terrain: terrain, step: step)
        if let node = meshNode {
            scene.rootNode.addChildNode(node)
        }

        // 등고선 생성
        contourNode = createContourNode(terrain: terrain, step: step)
        if let node = contourNode {
            scene.rootNode.addChildNode(node)
        }

        // 물 흐름 화살표 생성
        createWaterFlowArrows(terrain: terrain)
    }

    /// 퍼팅 궤적 3D 표시
    func showTrajectory(_ trajectory: [Vector2], terrain: HeightMapData,
                        ballPos: Vector2, holePos: Vector2) {
        trajectoryNode?.removeFromParentNode()

        var points: [SCNVector3] = []
        let halfW = Double(terrain.gridWidth) * terrain.cellSize / 2.0
        let halfH = Double(terrain.gridHeight) * terrain.cellSize / 2.0

        for pt in trajectory {
            let gx = max(0, min(terrain.gridWidth - 1, Int(pt.x / terrain.cellSize)))
            let gy = max(0, min(terrain.gridHeight - 1, Int(pt.y / terrain.cellSize)))
            let h = terrain.getHeight(x: gx, y: gy)
            points.append(SCNVector3(
                Float(pt.x - halfW),
                Float(h) * heightScale + 0.05, // 메쉬 위에 약간 띄움
                Float(pt.y - halfH)
            ))
        }

        guard points.count >= 2 else { return }

        // 궤적 라인 노드 생성
        let lineNode = createLineNode(points: points,
                                       color: UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0),
                                       lineWidth: 3.0)
        scene.rootNode.addChildNode(lineNode)
        trajectoryNode = lineNode

        // 볼 마커
        let ballScn = createSphereMarker(at: points.first!, color: .white, radius: 0.08)
        scene.rootNode.addChildNode(ballScn)

        // 홀 마커
        let holeScn = createSphereMarker(at: points.last!, color: .red, radius: 0.12)
        scene.rootNode.addChildNode(holeScn)
    }

    // MARK: - Mesh Generation

    /// 적응형 스텝 (그리드 크기에 따라 LOD 자동 조절)
    private func adaptiveStep(for terrain: HeightMapData) -> Int {
        let totalCells = terrain.gridWidth * terrain.gridHeight
        if totalCells > 100000 { return 4 }
        if totalCells > 40000  { return 2 }
        return 1
    }

    /// 높이 맵에서 SceneKit 메쉬 노드 생성
    private func createMeshNode(terrain: HeightMapData, step: Int) -> SCNNode {
        let w = terrain.gridWidth
        let h = terrain.gridHeight
        let halfW = Float(w) * Float(terrain.cellSize) / 2.0
        let halfH = Float(h) * Float(terrain.cellSize) / 2.0
        let minH = terrain.minHeight
        let maxH = terrain.maxHeight
        let range = max(maxH - minH, 0.0001)

        // 버텍스 생성
        let steppedW = (w - 1) / step + 1
        let steppedH = (h - 1) / step + 1

        var vertices:  [SCNVector3] = []
        var normals:   [SCNVector3] = []
        var colors:    [SCNVector3] = []
        var texCoords: [CGPoint]    = []

        vertices.reserveCapacity(steppedW * steppedH)
        normals.reserveCapacity(steppedW * steppedH)
        colors.reserveCapacity(steppedW * steppedH)

        for gy in stride(from: 0, to: h, by: step) {
            for gx in stride(from: 0, to: w, by: step) {
                let height = Float(terrain.getHeight(x: gx, y: gy))
                let x = Float(gx) * Float(terrain.cellSize) - halfW
                let z = Float(gy) * Float(terrain.cellSize) - halfH

                vertices.append(SCNVector3(x, height * heightScale, z))

                // 법선 계산 (중앙차분)
                let hL = Float(terrain.getHeight(x: max(0, gx - step), y: gy))
                let hR = Float(terrain.getHeight(x: min(w - 1, gx + step), y: gy))
                let hD = Float(terrain.getHeight(x: gx, y: max(0, gy - step)))
                let hU = Float(terrain.getHeight(x: gx, y: min(h - 1, gy + step)))
                let dx = (hR - hL) * heightScale
                let dz = (hU - hD) * heightScale
                let scale = Float(step) * Float(terrain.cellSize) * 2.0
                let nx = -dx / scale
                let nz = -dz / scale
                let len = sqrt(nx * nx + 1.0 + nz * nz)
                normals.append(SCNVector3(nx / len, 1.0 / len, nz / len))

                // 높이 기반 색상 (초록→노랑→빨강)
                let t = Float((terrain.getHeight(x: gx, y: gy) - minH) / range)
                let (cr, cg, cb) = heightToColor(t)
                colors.append(SCNVector3(cr, cg, cb))

                texCoords.append(CGPoint(x: CGFloat(gx) / CGFloat(w),
                                          y: CGFloat(gy) / CGFloat(h)))
            }
        }

        // 인덱스 생성 (삼각형)
        var indices: [UInt32] = []
        indices.reserveCapacity((steppedW - 1) * (steppedH - 1) * 6)

        for gy in 0..<(steppedH - 1) {
            for gx in 0..<(steppedW - 1) {
                let topLeft     = UInt32(gy * steppedW + gx)
                let topRight    = topLeft + 1
                let bottomLeft  = UInt32((gy + 1) * steppedW + gx)
                let bottomRight = bottomLeft + 1

                // 삼각형 1
                indices.append(topLeft)
                indices.append(bottomLeft)
                indices.append(topRight)

                // 삼각형 2
                indices.append(topRight)
                indices.append(bottomLeft)
                indices.append(bottomRight)
            }
        }

        // SCNGeometry 생성
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let colorSource  = SCNGeometrySource(
            data: Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector3>.stride),
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.stride
        )

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource],
                                    elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents  = UIColor.white
        material.isDoubleSided     = true
        material.lightingModel     = .physicallyBased
        material.metalness.contents = 0.1
        material.roughness.contents = 0.8
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "terrain_mesh"
        return node
    }

    // MARK: - Contour Lines

    private func createContourNode(terrain: HeightMapData, step: Int) -> SCNNode {
        let parentNode = SCNNode()
        parentNode.name = "contours"

        let minH = terrain.minHeight
        let maxH = terrain.maxHeight
        let contourInterval = 0.01 // 1cm
        let halfW = Double(terrain.gridWidth) * terrain.cellSize / 2.0
        let halfH = Double(terrain.gridHeight) * terrain.cellSize / 2.0

        let contourStep = max(2, step)

        var level = (minH / contourInterval).rounded(.down) * contourInterval
        while level <= maxH {
            let isMajor = abs(level.remainder(dividingBy: 0.05)) < 0.001

            var linePoints: [SCNVector3] = []

            for y in stride(from: 0, to: terrain.gridHeight - contourStep, by: contourStep) {
                for x in stride(from: 0, to: terrain.gridWidth - contourStep, by: contourStep) {
                    let h00 = terrain.getHeight(x: x, y: y)
                    let h10 = terrain.getHeight(x: x + contourStep, y: y)

                    if (h00 - level) * (h10 - level) < 0 {
                        let t = (level - h00) / (h10 - h00)
                        let px = (Double(x) + t * Double(contourStep)) * terrain.cellSize - halfW
                        let pz = Double(y) * terrain.cellSize - halfH
                        linePoints.append(SCNVector3(
                            Float(px),
                            Float(level) * heightScale + 0.01,
                            Float(pz)
                        ))
                    }
                }
            }

            if linePoints.count >= 2 && isMajor {
                let color: UIColor = isMajor
                    ? UIColor.white.withAlphaComponent(0.6)
                    : UIColor.white.withAlphaComponent(0.25)
                let width: CGFloat = isMajor ? 1.5 : 0.5

                // 점들을 작은 구로 표시 (등고선 근사)
                for pt in linePoints {
                    let sphere = SCNSphere(radius: width * 0.003)
                    sphere.firstMaterial?.diffuse.contents = color
                    sphere.firstMaterial?.lightingModel = .constant
                    let node = SCNNode(geometry: sphere)
                    node.position = pt
                    parentNode.addChildNode(node)
                }
            }

            level += contourInterval
        }

        return parentNode
    }

    // MARK: - Water Flow Arrows

    private func createWaterFlowArrows(terrain: HeightMapData) {
        let spacing = 0.30
        let tw = Double(terrain.gridWidth) * terrain.cellSize
        let th = Double(terrain.gridHeight) * terrain.cellSize
        let halfW = tw / 2.0
        let halfH = th / 2.0

        let slopeInfo = TerrainAnalyzer.calculateSlopeMagnitudeMap(terrain: terrain, spacing: spacing)
        let maxSlope = slopeInfo.maxSlope

        var gy = spacing
        while gy < th - 0.001 {
            var gx = spacing
            while gx < tw - 0.001 {
                let cx = Int(gx / terrain.cellSize)
                let cy = Int(gy / terrain.cellSize)
                let slope = TerrainAnalyzer.calculateHighPrecisionSlope(terrain: terrain, x: cx, y: cy)
                let mag = slope.length

                if mag > 0.003 {
                    let slopeRatio = min(mag / maxSlope, 1.0)
                    let norm = slope.normalized()
                    let arrowLen = min(mag * 3.0, 0.12)

                    let baseH = Float(terrain.getHeight(x: cx, y: cy)) * heightScale + 0.02
                    let from = SCNVector3(Float(gx - halfW), baseH, Float(gy - halfH))
                    let to = SCNVector3(
                        Float(gx - halfW + norm.x * arrowLen),
                        baseH,
                        Float(gy - halfH + norm.y * arrowLen)
                    )

                    let color = slopeGradientColor3D(ratio: slopeRatio)
                    let arrow = create3DArrow(from: from, to: to, color: color)
                    scene.rootNode.addChildNode(arrow)
                    arrowNodes.append(arrow)
                }

                gx += spacing
            }
            gy += spacing
        }
    }

    // MARK: - Helpers

    private func heightToColor(_ t: Float) -> (Float, Float, Float) {
        let ct = max(0, min(1, t))
        if ct < 0.33 {
            let f = ct / 0.33
            return (0.1 + f * 0.2, 0.37 + f * 0.32, 0.12 + f * 0.1) // 어두운 초록 → 밝은 초록
        } else if ct < 0.66 {
            let f = (ct - 0.33) / 0.33
            return (0.3 + f * 0.5, 0.69 + f * 0.17, 0.22 - f * 0.1) // 초록 → 노랑
        } else {
            let f = (ct - 0.66) / 0.34
            return (0.8 + f * 0.16, 0.86 - f * 0.6, 0.12 - f * 0.12) // 노랑 → 빨강
        }
    }

    private func slopeGradientColor3D(ratio: Double) -> UIColor {
        let r = max(0, min(1, ratio))
        if r < 0.5 {
            let t = r / 0.5
            return UIColor(red: CGFloat(t), green: 0.85, blue: CGFloat(0.15 * (1 - t)), alpha: 0.9)
        } else {
            let t = (r - 0.5) / 0.5
            return UIColor(red: 1.0, green: CGFloat(0.85 * (1 - t)), blue: 0, alpha: 0.9)
        }
    }

    private func create3DArrow(from: SCNVector3, to: SCNVector3, color: UIColor) -> SCNNode {
        let dx = to.x - from.x
        let dz = to.z - from.z
        let length = sqrt(dx * dx + dz * dz)
        guard length > 0.001 else { return SCNNode() }

        let parent = SCNNode()
        parent.position = from

        // 화살표 샤프트 (실린더)
        let shaftLen = length * 0.65
        let shaft = SCNCylinder(radius: 0.003, height: CGFloat(shaftLen))
        shaft.firstMaterial?.diffuse.contents = color
        shaft.firstMaterial?.lightingModel = .constant
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.position = SCNVector3(dx * 0.325, 0, dz * 0.325)

        // 방향 정렬
        let angle = atan2(dx, dz)
        shaftNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
        shaftNode.pivot = SCNMatrix4MakeRotation(-angle, 0, 1, 0)
        parent.addChildNode(shaftNode)

        // 화살촉 (원뿔)
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.008, height: CGFloat(length * 0.35))
        cone.firstMaterial?.diffuse.contents = color
        cone.firstMaterial?.lightingModel = .constant
        let coneNode = SCNNode(geometry: cone)
        coneNode.position = SCNVector3(dx * 0.825, 0, dz * 0.825)
        parent.addChildNode(coneNode)

        return parent
    }

    private func createLineNode(points: [SCNVector3], color: UIColor, lineWidth: CGFloat) -> SCNNode {
        let parent = SCNNode()

        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]

            let dx = to.x - from.x
            let dy = to.y - from.y
            let dz = to.z - from.z
            let length = sqrt(dx * dx + dy * dy + dz * dz)
            guard length > 0.0001 else { continue }

            let cylinder = SCNCylinder(radius: lineWidth * 0.002, height: CGFloat(length))
            cylinder.firstMaterial?.diffuse.contents = color
            cylinder.firstMaterial?.lightingModel = .constant

            let node = SCNNode(geometry: cylinder)

            // 중간점에 위치
            node.position = SCNVector3(
                (from.x + to.x) / 2,
                (from.y + to.y) / 2,
                (from.z + to.z) / 2
            )

            // 방향 정렬
            let dir = SCNVector3(dx / length, dy / length, dz / length)
            let up = SCNVector3(0, 1, 0)
            let cross = SCNVector3(
                up.y * dir.z - up.z * dir.y,
                up.z * dir.x - up.x * dir.z,
                up.x * dir.y - up.y * dir.x
            )
            let crossLen = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
            if crossLen > 0.0001 {
                let angle = acos(max(-1, min(1, up.x * dir.x + up.y * dir.y + up.z * dir.z)))
                node.rotation = SCNVector4(cross.x / crossLen, cross.y / crossLen, cross.z / crossLen, angle)
            }

            parent.addChildNode(node)
        }

        return parent
    }

    private func createSphereMarker(at position: SCNVector3, color: UIColor, radius: CGFloat) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .physicallyBased
        let node = SCNNode(geometry: sphere)
        node.position = position
        return node
    }
}
