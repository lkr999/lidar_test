import Vision
import UIKit

/// 화면에서 감지된 원형/타원형 객체
struct DetectedCircle {
    let screenRect: CGRect      // 스크린 좌표 (origin: top-left)
    var center: CGPoint { CGPoint(x: screenRect.midX, y: screenRect.midY) }
    var area: CGFloat  { screenRect.width * screenRect.height }
    var role: CircleRole = .unknown

    enum CircleRole { case ball, hole, unknown }
}

/// Vision 기반 원형 물체 감지기 (홀컵·볼 인식)
@available(iOS 14.0, *)
enum VisionDetector {

    // MARK: - Public

    static func detectCircles(in image: UIImage,
                               viewSize: CGSize,
                               completion: @escaping ([DetectedCircle]) -> Void) {
        guard let cg = image.cgImage else { completion([]); return }

        let req = VNDetectContoursRequest()
        req.contrastAdjustment   = 2.2
        req.detectsDarkOnLight   = true

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])

        DispatchQueue.global(qos: .utility).async {
            try? handler.perform([req])

            guard let obs = req.results?.first as? VNContoursObservation else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var circles: [DetectedCircle] = []
            for contour in obs.topLevelContours {
                if let c = createCircleFromContour(contour, viewSize: viewSize) {
                    circles.append(c)
                }
            }

            // 크기 내림차순 정렬
            var sorted = circles.sorted { $0.area > $1.area }

            // 역할 초기화 (실제 배분은 MainViewController에서 수행)
            for i in 0..<sorted.count { sorted[i].role = .unknown }

            DispatchQueue.main.async { completion(Array(sorted.prefix(6))) }
        }
    }

    // MARK: - Private

    private static func createCircleFromContour(_ contour: VNContour,
                                                viewSize: CGSize) -> DetectedCircle? {
        let pts = contour.normalizedPoints
        guard contour.pointCount >= 6 else { return nil }

        // Bounding Box 계산 (min/max X, Y)
        var minX: Float = pts[0].x, maxX: Float = pts[0].x
        var minY: Float = pts[0].y, maxY: Float = pts[0].y
        
        for i in 1..<contour.pointCount {
            let p = pts[i]
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }

        let width  = CGFloat(maxX - minX) * viewSize.width
        let height = CGFloat(maxY - minY) * viewSize.height
        let rect   = CGRect(x: CGFloat(minX) * viewSize.width,
                            y: (1 - CGFloat(maxY)) * viewSize.height,
                            width: width, height: height)

        // 크기 필터
        guard width > 12 && height > 12 else { return nil }
        guard width < viewSize.width * 0.5 && height < viewSize.height * 0.5 else { return nil }

        // Aspect ratio (원형도 기본)
        let ratio = min(width, height) / max(width, height)
        guard ratio > 0.45 else { return nil }

        // 상세 원형도 점수 필터
        guard calculateCircularity(contour) > 0.35 else { return nil }

        return DetectedCircle(screenRect: rect)
    }

    private static func calculateCircularity(_ contour: VNContour) -> Float {
        let count = contour.pointCount
        let pts   = contour.normalizedPoints
        guard count >= 6 else { return 0 }

        var cx: Float = 0, cy: Float = 0
        for i in 0..<count { cx += pts[i].x; cy += pts[i].y }
        cx /= Float(count); cy /= Float(count)

        var totalDist: Float = 0
        var dists: [Float] = []
        for i in 0..<count {
            let dx = pts[i].x - cx, dy = pts[i].y - cy
            let d = sqrt(dx*dx + dy*dy)
            dists.append(d)
            totalDist += d
        }
        let meanDist = totalDist / Float(count)
        guard meanDist > 0 else { return 0 }

        var variance: Float = 0
        for d in dists { variance += pow(d - meanDist, 2) }
        variance /= Float(count)

        return max(0, min(1, 1.0 - sqrt(variance) / meanDist * 3.5))
    }
}
