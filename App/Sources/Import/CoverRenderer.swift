import Foundation
import PDFKit
import UIKit

/// Small JPEG thumbnails used as library covers (stored with each document).
enum CoverRenderer {
    static let width: CGFloat = 420

    static func pdfCover(_ pdf: PDFDocument) -> Data? {
        guard let page = pdf.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: width, height: width * bounds.height / bounds.width)
        let image = page.thumbnail(of: size, for: .cropBox)
        return flattened(image)
    }

    static func imageCover(_ image: UIImage) -> Data? {
        flattened(image)
    }

    static func imageCover(data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return flattened(image)
    }

    /// Downloads a page's preview image; gives up quietly on any failure.
    static func downloadCover(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count < 15_000_000
        else { return nil }
        return imageCover(data: data)
    }

    /// Scales down and draws on white (PDF pages are often transparent).
    private static func flattened(_ image: UIImage) -> Data? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, width / source.width)
        let target = CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.78)
    }
}
