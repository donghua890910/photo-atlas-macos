import Foundation
import Photos
import AppKit

public enum LocalPreview {
    /// Fetches a preview from iCloud when the image is not available locally.
    public static func jpeg(id: String, size: Int) async -> Data? {
        try? await requiredJPEG(id: id, size: size)
    }

    public static func requiredJPEG(id: String, size: Int) async throws -> Data {
        guard (1...2048).contains(size) else { throw StoreError.invalidInput }
        return try await Task.detached(priority: .utility) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { throw PreviewFailure.assetUnavailable }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw PreviewFailure.assetUnavailable }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            var jpeg: Data?
            var requestFailed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size), contentMode: .aspectFit, options: options) { image, info in
                if info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool == true) { requestFailed = true }
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
                jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            }
            if requestFailed { throw PreviewFailure.assetUnavailable }
            guard let jpeg else { throw PreviewFailure.noLocalPreview }
            return jpeg
        }.value
    }
}
