import FanCore
import SwiftUI
import UniformTypeIdentifiers

struct CoolingHistoryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension AppModel {
    var historyCSV: String {
        let formatter = ISO8601DateFormatter()
        let rows = visibleHistory.map { sample in
            let values = [sample.temperature, sample.rpm, sample.cpu].map { value in
                value.flatMap { $0.isFinite ? String($0) : nil } ?? ""
            }
            return ([formatter.string(from: sample.date)] + values).joined(separator: ",")
        }
        return (["timestamp,die_temperature_c,fastest_fan_rpm,cpu_percent"] + rows).joined(separator: "\n") + "\n"
    }
}
