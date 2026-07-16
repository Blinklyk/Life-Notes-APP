import Foundation

struct HTTPTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
}

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPTransportResponse
}

private final class BoundedURLSessionDelegate: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPTransportResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var responseData = Data()
    private var isCompleted = false
    private var wasCancelledByCaller = false

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func execute(
        session: URLSession,
        request: URLRequest
    ) async throws -> HTTPTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if wasCancelledByCaller {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancelFromCaller()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(HTTPTransportError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentEncoding == nil
                || contentEncoding == ""
                || contentEncoding == "identity" else {
            finish(.failure(HTTPTransportError.unsupportedContentEncoding))
            completionHandler(.cancel)
            return
        }
        let expectedContentLength = response.expectedContentLength
        guard expectedContentLength < 0
                || expectedContentLength <= Int64(maximumResponseBytes) else {
            finish(.failure(HTTPTransportError.responseTooLarge))
            completionHandler(.cancel)
            return
        }

        lock.lock()
        self.response = response
        if expectedContentLength >= 0 {
            responseData.reserveCapacity(Int(expectedContentLength))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        guard responseData.count + data.count <= maximumResponseBytes else {
            lock.unlock()
            finish(.failure(HTTPTransportError.responseTooLarge))
            dataTask.cancel()
            return
        }
        responseData.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        let result: Result<HTTPTransportResponse, Error>
        if wasCancelledByCaller {
            result = .failure(CancellationError())
        } else if let error {
            result = .failure(error)
        } else if let response {
            result = .success(
                HTTPTransportResponse(
                    data: responseData,
                    statusCode: response.statusCode,
                    finalURL: response.url
                )
            )
        } else {
            result = .failure(HTTPTransportError.invalidResponse)
        }
        isCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func cancelFromCaller() {
        lock.lock()
        wasCancelledByCaller = true
        let task = self.task
        let hasContinuation = continuation != nil
        lock.unlock()
        if hasContinuation {
            finish(.failure(CancellationError()))
        }
        task?.cancel()
    }

    private func finish(_ result: Result<HTTPTransportResponse, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

actor URLSessionHTTPTransport: HTTPTransport {
    private let configuration: URLSessionConfiguration
    private let maximumResponseBytes: Int

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = RemoteJournalGenerator.maximumResponseBytes
    ) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.maximumResponseBytes = maximumResponseBytes
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResponse {
        var boundedRequest = request
        boundedRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let delegate = BoundedURLSessionDelegate(
            maximumResponseBytes: maximumResponseBytes
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        return try await delegate.execute(session: session, request: boundedRequest)
    }
}

enum HTTPTransportError: Error, Equatable, Sendable {
    case invalidResponse
    case responseTooLarge
    case unsupportedContentEncoding
}

protocol AIBackendHealthChecking: Sendable {
    func check(baseURL: URL) async throws
}

enum AIBackendHealthCheckError: LocalizedError, Equatable, Sendable {
    case unexpectedStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(statusCode):
            return "后端健康检查返回了 HTTP \(statusCode)。"
        case .invalidResponse:
            return "后端健康检查响应无效。"
        }
    }
}

struct HTTPAIBackendHealthChecker: AIBackendHealthChecking {
    private struct HealthResponse: Decodable {
        let status: String
    }

    let transport: any HTTPTransport

    func check(baseURL: URL) async throws {
        var request = URLRequest(
            url: baseURL.appendingAPIPath("health"),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 8
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPTransportResponse
        do {
            response = try await transport.data(for: request)
        } catch is HTTPTransportError {
            throw AIBackendHealthCheckError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw AIBackendHealthCheckError.unexpectedStatus(response.statusCode)
        }
        guard response.data.count <= 4_096,
              let health = try? JSONDecoder().decode(HealthResponse.self, from: response.data),
              health.status == "ok" else {
            throw AIBackendHealthCheckError.invalidResponse
        }
    }
}
