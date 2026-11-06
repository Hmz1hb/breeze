import CHardware
import Foundation

public enum Wire {
    public static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        let result = data.withUnsafeBytes { buffer in
            breeze_send(fd, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), buffer.count)
        }
        guard result == 0 else { throw FanError("The control helper disconnected.") }
    }
    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32, timeout: Int32) throws -> T? {
        var bytes = [CChar](repeating: 0, count: 8192)
        let count = breeze_receive(fd, &bytes, bytes.count, timeout)
        guard count >= 0 else { throw FanError("The control helper disconnected or sent an invalid response.") }
        guard count > 0 else { return nil }
        let data = bytes.withUnsafeBytes { Data($0.prefix(Int(count))) }
        return try JSONDecoder().decode(type, from: data)
    }
}
