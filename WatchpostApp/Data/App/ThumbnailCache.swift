import Foundation
import ImageIO
import Observation
import UIKit

/// Stills for the event rows, kept in memory and requested once per URL
/// however many rows ask at the same time.
@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [MediaRequest: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 400
    }

    func cached(_ request: MediaRequest) -> UIImage? {
        cache.object(forKey: request.url.absoluteString as NSString)
    }

    func image(for request: MediaRequest,
               load: @escaping @Sendable (MediaRequest) async throws -> Data) async -> UIImage? {
        let key = request.url.absoluteString as NSString
        if let ready = cache.object(forKey: key) { return ready }
        if let running = inFlight[request] {
            return await running.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let data = try? await load(request), let image = await Self.decode(data) else { return nil }
            await MainActor.run { [weak self] in self?.cache.setObject(image, forKey: key) }
            return image
        }
        inFlight[request] = task
        let image = await task.value
        inFlight[request] = nil
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private nonisolated static func decode(_ data: Data) async -> UIImage? {
        // Decoded off the main actor and fully unpacked, so scrolling never decodes on the way.
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        return image.map { UIImage(cgImage: $0) }
    }
}
