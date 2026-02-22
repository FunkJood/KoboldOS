import Foundation

// MARK: - ToolResult

public enum ToolResult: Sendable {
    case success(output: String, data: [String: String] = [:])
    case failure(error: String, code: Int = 0)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var isFailure: Bool { !isSuccess }

    public var output: String? {
        if case .success(let out, _) = self { return out }
        return nil
    }

    public var errorMessage: String? {
        if case .failure(let err, _) = self { return err }
        return nil
    }

    public var outputOrError: String {
        switch self {
        case .success(let out, _): return out
        case .failure(let err, _): return "Error: \(err)"
        }
    }

    public static func ok(_ output: String, data: [String: String] = [:]) -> ToolResult {
        .success(output: output, data: data)
    }

    public static func fail(_ error: String, code: Int = 1) -> ToolResult {
        .failure(error: error, code: code)
    }
}
