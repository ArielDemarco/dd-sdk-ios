import Foundation
@testable import Datadog

/*
A collection of mock configurations for SDK.
It follows the mocking conventions described in `FoundationMocks.swift`.
 */

extension Datadog {
    static func mockAny() -> Datadog {
        return .mockUsing(logsEndpoint: "https://api.example.com/v1", clientToken: "abcdefghi")
    }
    
    static func mockUsing(logsEndpoint: String, clientToken: String) -> Datadog {
        return try! Datadog(logsEndpoint: logsEndpoint, clientToken: clientToken)
    }
}

extension LogsUploader {
    /// Mocks `LogsUploader` instance which notifies sent requests on `captureBlock`.
    static func mockUploaderCapturingRequests(captureBlock: @escaping (URLRequest) -> Void) -> LogsUploader {
        return LogsUploader(
            configuration: .mockAny(),
            httpClient: .mockRequestCapture(captureBlock: captureBlock)
        )
    }
}
