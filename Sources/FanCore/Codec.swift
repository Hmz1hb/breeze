import Foundation

public enum SMCCodec {
    public static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset*8) }
            let result = Double(Float(bitPattern: bits))
            return result.isFinite ? result : nil
        case "ui8 " where bytes.count == 1, "flag" where bytes.count == 1: return bytes.first.map(Double.init)
        case "ui16" where bytes.count == 2, "ui32" where bytes.count == 4:
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }
    public static func encode(_ value: Double, type: String, size: Int) throws -> [UInt8] {
        guard value.isFinite, value >= 0 else { throw FanError("Invalid SMC value.") }
        switch (type, size) {
        case ("flt ", 4):
            guard value <= Double(Float.greatestFiniteMagnitude) else { throw FanError("Value is too large.") }
            let bits = Float(value).bitPattern
            return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0*8)) }
        case ("fpe2", 2):
            guard value <= 16383.75 else { throw FanError("RPM exceeds encoding range.") }
            let bits = UInt16((value*4).rounded())
            return [UInt8(bits >> 8), UInt8(truncatingIfNeeded: bits)]
        case ("ui8 ", 1), ("flag", 1):
            guard value <= 255 else { throw FanError("Value exceeds encoding range.") }
            return [UInt8(value.rounded())]
        default: throw FanError("Unsupported writable SMC type: \(type).")
        }
    }
}
