import Foundation
import ImageIO

enum PhotoCaptureDate {
    static func read(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        return read(from: properties)
    }

    static func read(from properties: [String: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        return parse(
            exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            offset: exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        ) ?? parse(
            tiff?[kCGImagePropertyTIFFDateTime as String] as? String,
            offset: exif?[kCGImagePropertyExifOffsetTime as String] as? String
        )
    }

    private static func parse(_ value: String?, offset: String?) -> Date? {
        guard let value else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false

        // Foundation can normalize dates such as February 29 in a non-leap year.
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }

        if let offset {
            formatter.dateFormat += "XXXXX"
            if let date = formatter.date(from: value + offset) { return date }
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        }
        formatter.timeZone = .current
        return formatter.date(from: value)
    }
}
