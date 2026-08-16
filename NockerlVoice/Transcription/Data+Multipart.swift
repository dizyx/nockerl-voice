import Foundation

extension Data {
    /// Append a UTF-8 string (used when hand-building multipart bodies).
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
