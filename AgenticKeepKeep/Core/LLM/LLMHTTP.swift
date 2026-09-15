import Foundation

/// 共用的 HTTP 发送逻辑（超时、重试、错误映射）
enum LLMHTTP {

    static func post(
        url: URL,
        body: Data,
        headers: [String: String],
        config: LLMClientConfig,
        session: URLSession,
        refreshBody: (() throws -> Data)? = nil
    ) async throws -> Data {
        var attempt = 0
        var lastError: LLMError = .emptyResponse

        while attempt <= config.maxRetries {
            attempt += 1
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = config.timeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                request.httpBody = try refreshBody?() ?? body

                let (data, response) = try await session.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.network("响应格式异常")
                }

                guard (200...299).contains(http.statusCode) else {
                    let error = LLMError.http(status: http.statusCode, body: llmShortBody(data))
                    // 5xx 可重试
                    if http.statusCode >= 500, attempt <= config.maxRetries {
                        lastError = error
                        continue
                    }
                    throw error
                }

                return data
            } catch let error as LLMError {
                throw error
            } catch is CancellationError {
                throw LLMError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                throw LLMError.cancelled
            } catch {
                let mapped = LLMError.network(error.localizedDescription)
                if attempt <= config.maxRetries {
                    lastError = mapped
                    continue
                }
                throw mapped
            }
        }

        throw lastError
    }
}
