import Foundation

struct DiveSample: Identifiable, Codable, Equatable {
    let id: Int
    let elapsedSeconds: Double
    let depthMeters: Double
    let temperatureCelsius: Double?
}

struct DiveRecord: Codable, Equatable {
    let manufacturer: String?
    let computerModel: String?
    let serialNumber: String?
    let dateTime: String?
    let durationSeconds: Double?
    let maximumDepthMeters: Double?
    let averageDepthMeters: Double?
    let samples: [DiveSample]
}

enum UDDFParseError: Error {
    case noDiveFound
    case noValidSamples
}

final class AtmosUDDFParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var waypoint: [String: String]?
    private var samples: [DiveSample] = []
    private var manufacturer: String?
    private var model: String?
    private var serial: String?
    private var dateTime: String?
    private var duration: Double?
    private var maxDepth: Double?
    private var avgDepth: Double?
    private var foundDive = false

    func parse(data: Data) throws -> DiveRecord {
        reset()
        let xml = XMLParser(data: data)
        xml.delegate = self
        xml.shouldResolveExternalEntities = false
        guard xml.parse(), foundDive else {
            throw xml.parserError ?? UDDFParseError.noDiveFound
        }
        let ordered = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard !ordered.isEmpty else { throw UDDFParseError.noValidSamples }
        return DiveRecord(
            manufacturer: manufacturer, computerModel: model, serialNumber: serial,
            dateTime: dateTime, durationSeconds: duration, maximumDepthMeters: maxDepth,
            averageDepthMeters: avgDepth, samples: ordered
        )
    }

    private func reset() {
        path = []; text = ""; waypoint = nil; samples = []
        manufacturer = nil; model = nil; serial = nil; dateTime = nil
        duration = nil; maxDepth = nil; avgDepth = nil; foundDive = false
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        path.append(name)
        text = ""
        if name == "dive" { foundDive = true }
        if name == "waypoint" { waypoint = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var point = waypoint {
            if name != "waypoint", !value.isEmpty { point[name] = value }
            if name == "waypoint" {
                append(point)
                waypoint = nil
            } else {
                waypoint = point
            }
        } else if !value.isEmpty {
            switch name {
            case "name":
                if path.suffix(2).map({ $0 }) == ["manufacturer", "name"] {
                    // Keep the dive-computer manufacturer, not the generator's company.
                    if path.contains("divecomputer") { manufacturer = value }
                } else if path.contains("divecomputer"), model == nil,
                          value.localizedCaseInsensitiveContains("mission") {
                    model = value
                }
            case "model": model = value
            case "serialnumber": serial = value
            case "datetime": dateTime = value
            case "diveduration": duration = Double(value)
            case "greatestdepth": maxDepth = Double(value)
            case "averagedepth": avgDepth = Double(value)
            default: break
            }
        }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }

    private func append(_ values: [String: String]) {
        guard let t = Double(values["divetime"] ?? ""),
              let d = Double(values["depth"] ?? ""), t.isFinite, d.isFinite, d >= 0 else { return }
        let kelvin = Double(values["temperature"] ?? "")
        let celsius = kelvin.flatMap { k -> Double? in
            guard k.isFinite, (200...350).contains(k) else { return nil }
            return k - 273.15
        }
        samples.append(DiveSample(id: samples.count, elapsedSeconds: t,
                                  depthMeters: d, temperatureCelsius: celsius))
    }
}
