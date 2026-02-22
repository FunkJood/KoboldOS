#if os(Linux)
import Glibc
import Foundation

// MARK: - Raw TCP Socket Wrappers (Linux implementation)

public class ServerSocket: @unchecked Sendable {
    let fd: Int32

    public init?(port: Int) {
        fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Glibc.close(fd); return nil }
        guard listen(fd, 128) == 0 else { Glibc.close(fd); return nil }
    }

    public func accept() -> ClientSocket? {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.accept(fd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return nil }
        return ClientSocket(fd: clientFd)
    }

    public func close() {
        Glibc.close(fd)
    }
}

public class ClientSocket: @unchecked Sendable {
    let fd: Int32
    public init(fd: Int32) { self.fd = fd }

    public func readRequest(maxBytes: Int = 1_048_576) -> String? {
        // Set socket read timeout to 30 seconds to prevent indefinite blocking
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read the full HTTP request — loop to handle Content-Length framing
        var fullData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        // First read — get headers at minimum
        let n = recv(fd, &buffer, buffer.count - 1, 0)
        guard n > 0 else { return nil }
        fullData.append(contentsOf: buffer.prefix(n))

        // Find header/body separator
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = fullData.range(of: sep) else {
            return String(data: fullData, encoding: .utf8)
        }

        // Parse Content-Length from headers
        let headerData = fullData[fullData.startIndex..<sepRange.lowerBound]
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(val) ?? 0
                break
            }
        }

        // Reject bodies exceeding limit early
        if contentLength > maxBytes { return nil }

        // How much body do we already have?
        let headerEndIndex = fullData.index(sepRange.lowerBound, offsetBy: 4)
        let bodyAlreadyRead = fullData.count - fullData.distance(from: fullData.startIndex, to: headerEndIndex)

        // Loop-read remaining body bytes
        if contentLength > 0 && bodyAlreadyRead < contentLength {
            let remaining = contentLength - bodyAlreadyRead
            var bodyBuffer = [UInt8](repeating: 0, count: min(remaining, maxBytes))
            var readSoFar = 0
            while readSoFar < remaining {
                let nr = recv(fd, &bodyBuffer[readSoFar], bodyBuffer.count - readSoFar, 0)
                guard nr > 0 else { break }
                readSoFar += nr
            }
            fullData.append(contentsOf: bodyBuffer.prefix(readSoFar))
        }

        return String(data: fullData, encoding: .utf8)
    }

    public func write(_ response: String) {
        guard let data = response.data(using: .utf8) else { return }
        data.withUnsafeBytes { ptr in
            _ = Glibc.send(fd, ptr.baseAddress!, data.count, 0)
        }
    }

    public func close() {
        Glibc.close(fd)
    }
}
#endif