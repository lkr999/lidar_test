import UIKit
import CoreVideo

/// LiDAR 깊이 맵을 false-color 이미지로 변환하는 렌더러
///
/// - Jet colormap: 가까울수록 파랑 → 초록 → 빨강(멀수록)
/// - 신뢰도 낮은 픽셀은 어둡게 표시
/// - 자이로 기울기 인디케이터 오버레이 포함
/// - 카메라 RGB 이미지와 반투명 합성 가능
class DepthImageRenderer {

    // MARK: - Public API

    /// 깊이 버퍼 전체 픽셀을 false-color UIImage로 변환
    ///
    /// - Parameters:
    ///   - depthBuffer:      ARKit 깊이 맵 (kCVPixelFormatType_DepthFloat32, 단위: m)
    ///   - confidenceBuffer: ARKit 신뢰도 맵 (UInt8: 0=낮음/1=보통/2=높음), 없으면 모두 high로 가정
    ///   - minDepth:         색상 범위 최솟값 (m). 이보다 가까우면 짙은 파랑
    ///   - maxDepth:         색상 범위 최댓값 (m). 이보다 멀면 짙은 빨강
    ///   - tiltPitch:        기기 pitch 각도 (도). 수평 인디케이터 렌더링에 사용
    ///   - tiltRoll:         기기 roll 각도 (도)
    /// - Returns: 렌더링된 UIImage. 버퍼 접근 실패 시 nil
    static func renderDepthImage(
        depthBuffer: CVPixelBuffer,
        confidenceBuffer: CVPixelBuffer?,
        minDepth: Float = 0.15,
        maxDepth: Float = 10.0,
        tiltPitch: Double = 0,
        tiltRoll: Double = 0
    ) -> UIImage? {

        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        if let cb = confidenceBuffer { CVPixelBufferLockBaseAddress(cb, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
            if let cb = confidenceBuffer { CVPixelBufferUnlockBaseAddress(cb, .readOnly) }
        }

        let w = CVPixelBufferGetWidth(depthBuffer)
        let h = CVPixelBufferGetHeight(depthBuffer)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }

        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        var confPtr: UnsafePointer<UInt8>? = nil
        if let cb = confidenceBuffer, let base = CVPixelBufferGetBaseAddress(cb) {
            confPtr = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
        }

        let depthRange = maxDepth - minDepth

        // 픽셀당 RGBA 4바이트 — 모든 픽셀을 순회하여 색상 매핑
        var pixels = [UInt8](repeating: 255, count: w * h * 4)

        for y in 0 ..< h {
            for x in 0 ..< w {
                let i   = y * w + x
                let b4  = i * 4
                let depth = depthPtr[i]
                let conf  = confPtr?[i] ?? 2

                guard depth > minDepth && depth < maxDepth else {
                    // 유효 범위 밖 → 짙은 어두운색
                    pixels[b4]     = 18
                    pixels[b4 + 1] = 18
                    pixels[b4 + 2] = 22
                    pixels[b4 + 3] = 255
                    continue
                }

                // t: 0=멀다(빨강), 1=가깝다(파랑) – jet colormap 입력
                let t = Double(1.0 - (depth - minDepth) / depthRange)
                let (r, g, b) = jetColormap(saturate(t))

                // 신뢰도에 따라 밝기 조절
                let dim: Double = conf == 0 ? 0.38 : (conf == 1 ? 0.72 : 1.0)

                pixels[b4]     = UInt8(Double(r) * dim)
                pixels[b4 + 1] = UInt8(Double(g) * dim)
                pixels[b4 + 2] = UInt8(Double(b) * dim)
                pixels[b4 + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImg = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }

        let raw = UIImage(cgImage: cgImg)
        return addTiltOverlay(to: raw, pitchDeg: tiltPitch, rollDeg: tiltRoll)
    }

    /// 카메라 RGB 이미지 위에 깊이 이미지를 반투명 합성
    ///
    /// - Parameters:
    ///   - cameraImage: ARView 스냅샷 (RGB)
    ///   - depthImage:  `renderDepthImage`로 생성한 false-color 깊이 이미지
    ///   - alpha:       깊이 레이어 불투명도 (0=완전투명 / 1=완전불투명, 기본 0.45)
    /// - Returns: 합성된 UIImage
    static func compositeWithCamera(
        cameraImage: UIImage,
        depthImage: UIImage,
        alpha: CGFloat = 0.45
    ) -> UIImage {
        let size = cameraImage.size
        UIGraphicsBeginImageContextWithOptions(size, true, cameraImage.scale)
        defer { UIGraphicsEndImageContext() }

        cameraImage.draw(in: CGRect(origin: .zero, size: size))
        depthImage.draw(in: CGRect(origin: .zero, size: size),
                        blendMode: .normal, alpha: alpha)

        return UIGraphicsGetImageFromCurrentImageContext() ?? cameraImage
    }

    // MARK: - Colormap

    /// Jet colormap: 0(파랑) → 0.5(초록) → 1(빨강)
    static func jetColormap(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let r: Double
        let g: Double
        let b: Double

        switch t {
        case ..<0.125:
            r = 0;   g = 0;                   b = 0.5 + t * 4.0
        case ..<0.375:
            r = 0;   g = (t - 0.125) * 4.0;  b = 1.0
        case ..<0.625:
            r = (t - 0.375) * 4.0; g = 1.0;  b = 1.0 - (t - 0.375) * 4.0
        case ..<0.875:
            r = 1.0; g = 1.0 - (t - 0.625) * 4.0; b = 0
        default:
            r = 1.0 - (t - 0.875) * 4.0; g = 0; b = 0
        }

        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    // MARK: - Tilt Overlay

    /// 기울기 인디케이터를 이미지 우하단에 오버레이
    ///
    /// 원 안의 점이 수평 중심이면 녹색, 기울어지면 주황색으로 표시.
    static func addTiltOverlay(to image: UIImage, pitchDeg: Double, rollDeg: Double) -> UIImage {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        defer { UIGraphicsEndImageContext() }

        image.draw(at: .zero)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return UIGraphicsGetImageFromCurrentImageContext() ?? image
        }

        let r: CGFloat = min(size.width, size.height) * 0.09
        let margin: CGFloat = 8
        let cx = size.width  - margin - r
        let cy = size.height - margin - r

        // 배경 원
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

        // 테두리
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

        // 십자 기준선
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: cx - r * 0.7, y: cy))
        ctx.addLine(to: CGPoint(x: cx + r * 0.7, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - r * 0.7))
        ctx.addLine(to: CGPoint(x: cx, y: cy + r * 0.7))
        ctx.strokePath()

        // 기울기 점: roll → X축, pitch → Y축 (최대 ±45°)
        let maxDeg: Double = 45
        let dotX = cx + CGFloat(saturate(rollDeg  / maxDeg, lo: -1, hi: 1)) * r * 0.75
        let dotY = cy + CGFloat(saturate(pitchDeg / maxDeg, lo: -1, hi: 1)) * r * 0.75
        let dotR = r * 0.16

        let isLevel = abs(pitchDeg) < 5 && abs(rollDeg) < 5
        let dotColor: UIColor = isLevel
            ? UIColor(red: 0.2, green: 0.92, blue: 0.3, alpha: 1)
            : UIColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1)
        ctx.setFillColor(dotColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR,
                                    width: dotR * 2, height: dotR * 2))

        // 텍스트: P/R 각도
        let fs = r * 0.32
        let label = String(format: "P%.1f° R%.1f°", pitchDeg, rollDeg)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fs, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.88)
        ]
        label.draw(at: CGPoint(x: margin, y: size.height - margin - fs * 1.5),
                   withAttributes: attrs)

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    // MARK: - Helpers

    @inline(__always)
    private static func saturate(_ v: Double) -> Double {
        max(0, min(1, v))
    }

    @inline(__always)
    private static func saturate(_ v: Double, lo: Double, hi: Double) -> Double {
        max(lo, min(hi, v))
    }
}
