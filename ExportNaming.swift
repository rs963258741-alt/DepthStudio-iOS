import Foundation
import Photos

/// Names of exported videos. Exports are always new files: the imported video is a copy
/// in the app's temporary folder and is never written to, and each export gets a name no
/// earlier export (or the source) has:
///
///     DJI_20261128.mp4 → DJI_20261128_DepthStudio.mp4, then _DepthStudio_02.mp4, _03 …
///
/// The numbering continues across launches (the last number used for each source name is
/// remembered), and a name whose file still exists is skipped.
enum ExportNaming {
    static let suffix = "_DepthStudio"
    static let counterKey = "depthstudio.export-name-counters.v1"

    /// Folder for finished exports (temporary: the video is saved to Photos or shared from here).
    static var exportDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DepthStudio Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The source's name without its extension, safe as a file name ("DepthStudio" if unknown).
    static func baseName(fromOriginal name: String?) -> String {
        let raw = ((name ?? "") as NSString).deletingPathExtension
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "DepthStudio" : String(cleaned.prefix(80))
        // Re-exporting an export does not stack the suffix: …_DepthStudio_02 → …_DepthStudio_03.
        if let range = base.range(of: suffix, options: .backwards) {
            let tail = base[range.upperBound...]
            if tail.isEmpty || (tail.hasPrefix("_") && tail.dropFirst().allSatisfy(\.isNumber)) {
                let stripped = String(base[..<range.lowerBound])
                return stripped.isEmpty ? "DepthStudio" : stripped
            }
        }
        return base
    }

    /// "<base>_DepthStudio.mp4" for the first export, then "<base>_DepthStudio_02.mp4" …
    static func fileName(base: String, index: Int) -> String {
        index <= 1 ? "\(base)\(suffix).mp4" : "\(base)\(suffix)_\(String(format: "%02d", index)).mp4"
    }

    /// The next export file for a source video: after the last number used for this name,
    /// not an existing file, and never the source itself. The number is remembered by
    /// `recordExport` once the export has succeeded.
    static func nextOutputURL(originalName: String?, sourceURL: URL?, directory: URL = exportDirectory,
                              store: UserDefaults = .standard) -> URL {
        let base = baseName(fromOriginal: originalName)
        let counters = store.dictionary(forKey: counterKey) as? [String: Int] ?? [:]
        var index = (counters[base] ?? 0) + 1
        var candidate = directory.appendingPathComponent(fileName(base: base, index: index))
        while FileManager.default.fileExists(atPath: candidate.path)
                || candidate.standardizedFileURL == sourceURL?.standardizedFileURL {
            index += 1
            candidate = directory.appendingPathComponent(fileName(base: base, index: index))
        }
        return candidate
    }

    /// Remembers the number of a finished export, so the next export of the same video
    /// gets the next number (also after the app restarts).
    static func recordExport(at url: URL, originalName: String?, store: UserDefaults = .standard) {
        let base = baseName(fromOriginal: originalName)
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        let prefix = base + suffix
        guard name.hasPrefix(prefix) else { return }
        let tail = name.dropFirst(prefix.count)
        let index = tail.isEmpty ? 1 : Int(tail.dropFirst()) ?? 0
        guard index > 0 else { return }
        var counters = store.dictionary(forKey: counterKey) as? [String: Int] ?? [:]
        counters[base] = max(counters[base] ?? 0, index)
        store.set(counters, forKey: counterKey)
    }
}

/// Saves an exported video to Photos as a new item (the original video in Photos is never
/// touched), keeping the export's file name as the item's file name.
enum PhotoLibrarySaver {
    enum Failure: LocalizedError {
        case saveFailed
        var errorDescription: String? { "iOS 照片圖庫無法建立影片項目。" }
    }

    static func saveNewVideo(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: .video, fileURL: url, options: options)
            }) { success, error in
                if success { continuation.resume() } else { continuation.resume(throwing: error ?? Failure.saveFailed) }
            }
        }
    }
}
