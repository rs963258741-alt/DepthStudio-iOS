import Foundation
import ObjcFIT
import SwiftFIT

/// Decodes Garmin FIT dive logs with Garmin's native C++/Objective-C decoder,
/// then normalizes them into the exact DiveRecord model used by UDDF.
/// The native decoder is used instead of the early Swift-only decoder because
/// it supports the full FIT record stream, including compressed timestamps.
final class GarminFITParser {
    func parse(fileURL: URL) throws -> DiveRecord {
        guard fileURL.isFileURL else {
            throw GarminFITParseError.invalidFileURL
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GarminFITParseError.fileNotFound
        }

        let decoder = FITDecoder()
        guard decoder.isFIT(fileURL.path) else {
            throw GarminFITParseError.invalidHeader
        }
        guard decoder.checkIntegrity(fileURL.path) else {
            throw GarminFITParseError.integrityCheckFailed
        }

        let listener = FITListener()
        decoder.mesgDelegate = listener
        guard decoder.decodeFile(fileURL.path) else {
            throw GarminFITParseError.decodeFailed
        }

        let messages = listener.messages
        let timedSamples = messages.getRecordMesgs().compactMap { record -> TimedDepthSample? in
            guard record.isTimestampValid(),
                  record.isDepthValid() else {
                return nil
            }

            let timestamp = record.getTimestamp().date.timeIntervalSince1970
            let depth = Double(record.getDepth())
            guard timestamp.isFinite,
                  depth.isFinite,
                  depth >= 0,
                  depth <= 2_000 else {
                return nil
            }

            // Mirror the website importer: prefer an explicitly named water-
            // temperature developer field, then fall back to FIT Record.temperature.
            let validTemperature = Self.waterTemperature(from: record)
                ?? Self.nativeTemperature(from: record)

            return TimedDepthSample(timestamp: timestamp,
                                    depthMeters: depth,
                                    temperatureCelsius: validTemperature)
        }
        .sorted { $0.timestamp < $1.timestamp }

        guard timedSamples.count >= 2 else {
            throw GarminFITParseError.insufficientDepthSamples
        }

        // Match the website importer: when timestamps repeat, keep the last
        // valid record so interpolation never sees a zero-duration interval.
        var normalized: [TimedDepthSample] = []
        for point in timedSamples {
            if let previous = normalized.last,
               abs(previous.timestamp - point.timestamp) < 0.0001 {
                normalized[normalized.count - 1] = point
            } else {
                normalized.append(point)
            }
        }

        guard normalized.count >= 2 else {
            throw GarminFITParseError.duplicateTimestamps
        }

        let origin = normalized[0].timestamp
        let samples = normalized.enumerated().map { index, point in
            DiveSample(id: index,
                       elapsedSeconds: point.timestamp - origin,
                       depthMeters: point.depthMeters,
                       temperatureCelsius: point.temperatureCelsius)
        }

        let computedMaximum = samples.map(\.depthMeters).max() ?? 0
        let computedAverage = Self.trapezoidalAverageDepth(samples)
        let summary = messages.getDiveSummaryMesgs().first
        let declaredMaximum = summary.flatMap { item -> Double? in
            guard item.isMaxDepthValid() else { return nil }
            return Self.validDepth(Double(item.getMaxDepth()), allowZero: false)
        }
        let declaredAverage = summary.flatMap { item -> Double? in
            guard item.isAvgDepthValid() else { return nil }
            return Self.validDepth(Double(item.getAvgDepth()), allowZero: true)
        }

        let fileID = messages.getFileIdMesgs().first
        let rawProductName = fileID.flatMap { item -> String? in
            guard item.isProductNameValid() else { return nil }
            return item.getProductName()
        }
        let productName = rawProductName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = (productName?.isEmpty == false) ? productName : "Garmin"

        let serialNumber: String?
        if let fileID, fileID.isSerialNumberValid() {
            serialNumber = String(fileID.getSerialNumber())
        } else {
            serialNumber = nil
        }

        let startDate = Date(timeIntervalSince1970: origin)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let duration = max(0, samples.last!.elapsedSeconds - samples.first!.elapsedSeconds)

        return DiveRecord(
            manufacturer: "Garmin",
            computerModel: modelName,
            serialNumber: serialNumber,
            dateTime: formatter.string(from: startDate),
            durationSeconds: duration,
            maximumDepthMeters: declaredMaximum ?? computedMaximum,
            averageDepthMeters: declaredAverage ?? computedAverage,
            samples: samples
        )
    }

    private static func waterTemperature(from record: FITRecordMesg) -> Double? {
        for case let field as FITDeveloperField in record.getDeveloperFields() {
            let definition = field.definition
            let names = (0..<Int(definition.numFieldNameValues)).compactMap { index -> String? in
                let fieldIndex = UInt8(index)
                guard definition.isFieldNameValidforIndex(fieldIndex) else { return nil }
                return definition.getFieldNameforIndex(fieldIndex)
            }
            let name = names.joined(separator: " ")
            guard name.range(of: "water.*temp|temp.*water", options: [.regularExpression, .caseInsensitive]) != nil,
                  let rawValue = field.getValueForIndex(0)?.doubleValue else {
                continue
            }

            let scale = definition.isScaleValid() ? max(1.0, Double(definition.getScale())) : 1.0
            let offset = definition.isOffsetValid() ? Double(definition.getOffset()) : 0.0
            let value = rawValue / scale - offset
            if value.isFinite, (-10.0...60.0).contains(value) { return value }
        }
        return nil
    }

    private static func nativeTemperature(from record: FITRecordMesg) -> Double? {
        guard record.isTemperatureValid() else { return nil }
        let value = Double(record.getTemperature())
        return value.isFinite && (-10.0...60.0).contains(value) ? value : nil
    }

    private static func validDepth(_ value: Double, allowZero: Bool) -> Double? {
        guard value.isFinite, value <= 2_000,
              allowZero ? value >= 0 : value > 0 else {
            return nil
        }
        return value
    }

    private static func trapezoidalAverageDepth(_ samples: [DiveSample]) -> Double {
        guard samples.count >= 2 else { return samples.first?.depthMeters ?? 0 }
        var area = 0.0
        var elapsed = 0.0
        for index in 1..<samples.count {
            let a = samples[index - 1]
            let b = samples[index]
            let interval = b.elapsedSeconds - a.elapsedSeconds
            guard interval > 0 else { continue }
            area += ((a.depthMeters + b.depthMeters) / 2) * interval
            elapsed += interval
        }
        return elapsed > 0
            ? area / elapsed
            : samples.reduce(0) { $0 + $1.depthMeters } / Double(samples.count)
    }
}

private struct TimedDepthSample {
    let timestamp: TimeInterval
    let depthMeters: Double
    let temperatureCelsius: Double?
}

enum GarminFITParseError: LocalizedError {
    case invalidFileURL
    case fileNotFound
    case invalidHeader
    case integrityCheckFailed
    case decodeFailed
    case insufficientDepthSamples
    case duplicateTimestamps

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            return "無法讀取這個 FIT 檔案位置。"
        case .fileNotFound:
            return "找不到選取的 FIT 檔案，請重新選取。"
        case .invalidHeader:
            return "檔案標頭不是有效的 Garmin FIT 格式。"
        case .integrityCheckFailed:
            return "FIT 檔案完整性檢查失敗（標頭或 CRC 不符），請重新匯出。"
        case .decodeFailed:
            return "Garmin FIT 解碼器無法讀取檔案，請確認這是完整的單筆潛水紀錄。"
        case .insufficientDepthSamples:
            return "FIT 檔沒有至少兩筆帶時間戳的有效深度資料。請確認匯出的是單筆潛水紀錄。"
        case .duplicateTimestamps:
            return "FIT 深度資料的時間戳重複，無法建立有效時間軸。"
        }
    }
}
