import Foundation
import UIKit

/// 图片压缩：发给视觉模型前先降采样，省 token 也更快
enum ImageDownscaler {

    /// 把任意图片数据转成 base64 JPEG（不含 data: 前缀）
    static func jpegBase64(
        from data: Data,
        maxDimension: CGFloat = 1024,
        quality: CGFloat = 0.7
    ) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegBase64(from: image, maxDimension: maxDimension, quality: quality)
    }

    static func jpegBase64(
        from image: UIImage,
        maxDimension: CGFloat = 1024,
        quality: CGFloat = 0.7
    ) -> String? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        return resized.jpegData(compressionQuality: quality)?.base64EncodedString()
    }

    /// 压缩为可存库的 JPEG 数据
    static func jpegData(from data: Data, maxDimension: CGFloat = 1280, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
