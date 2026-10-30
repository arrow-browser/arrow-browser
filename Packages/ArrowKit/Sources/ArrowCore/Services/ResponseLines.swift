import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Splits a streamed response body into lines (LF or CRLF), as bytes arrive.
struct LineBuffer {
    private var pending = Data()

    /// The lines completed by `data`.
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[pending.startIndex..<end]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }

    /// The last line, when the body does not end with a line break.
    mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

#if canImport(FoundationNetworking)
/// `URLSession.bytes(for:)` and `AsyncBytes.lines` exist only on Apple
/// platforms: elsewhere the lines come from a data task's delegate.
extension URLSession {
    /// Starts `request` and returns once the response arrived, with the lines
    /// of its body.
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let delegate = LineDelegate(lines: continuation)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in
            task.cancel()
            session.finishTasksAndInvalidate()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (response: CheckedContinuation<Void, Error>) in
                delegate.response = response
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return stream
    }
}

/// Runs on the session's serial delegate queue.
private final class LineDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var response: CheckedContinuation<Void, Error>?
    private let lines: AsyncThrowingStream<String, Error>.Continuation
    private var buffer = LineBuffer()

    init(lines: AsyncThrowingStream<String, Error>.Continuation) {
        self.lines = lines
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response?.resume()
        self.response = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for line in buffer.append(data) { lines.yield(line) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            response?.resume(throwing: error)
            lines.finish(throwing: error)
        } else {
            response?.resume()
            if let last = buffer.finish() { lines.yield(last) }
            lines.finish()
        }
        response = nil
    }
}
#endif
