import Foundation
import HTTPTypes
import OpenAPIRuntime

struct BearerMiddleware: ClientMiddleware {
    let vault: SessionVault

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = await vault.value() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}
