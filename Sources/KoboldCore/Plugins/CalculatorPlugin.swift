import Foundation

// MARK: - CalculatorPlugin — Sample built-in plugin

public struct CalculatorPlugin: KoboldPlugin {

    public static let manifest = PluginManifest(
        name: "calculator",
        version: "1.0.0",
        author: "KoboldOS",
        description: "Mathematical calculator with factorial, prime check, and expression evaluation",
        permissions: [],
        toolName: "calculator",
        minKoboldVersion: "1.0.0"
    )

    public let name = "calculator"
    public let description = "Evaluate math expressions and perform calculations"
    public let riskLevel: RiskLevel = .low

    public var schema: ToolSchema {
        ToolSchema(
            properties: [
                "expression": ToolSchemaProperty(
                    type: "string",
                    description: "Math expression or operation (e.g. '2+2', 'factorial(5)', 'prime(17)')",
                    required: true
                )
            ],
            required: ["expression"]
        )
    }

    public init() {}

    public func execute(arguments: [String: String]) async throws -> String {
        guard let expr = arguments["expression"], !expr.isEmpty else {
            throw ToolError.missingRequired("expression")
        }

        let clean = expr.trimmingCharacters(in: .whitespaces).lowercased()

        // Factorial
        if clean.hasPrefix("factorial(") || clean.hasPrefix("fact(") {
            let inner = extractInner(clean)
            guard let n = Int(inner), n >= 0, n <= 20 else {
                throw ToolError.invalidParameter("expression", "factorial requires 0-20")
            }
            let result = factorial(n)
            return "factorial(\(n)) = \(result)"
        }

        // Prime check
        if clean.hasPrefix("prime(") || clean.hasPrefix("isprime(") {
            let inner = extractInner(clean)
            guard let n = Int(inner) else {
                throw ToolError.invalidParameter("expression", "prime check requires integer")
            }
            let result = isPrime(n)
            return "\(n) is \(result ? "prime" : "not prime")"
        }

        // Fibonacci
        if clean.hasPrefix("fib(") || clean.hasPrefix("fibonacci(") {
            let inner = extractInner(clean)
            guard let n = Int(inner), n >= 0, n <= 50 else {
                throw ToolError.invalidParameter("expression", "fibonacci requires 0-50")
            }
            return "fib(\(n)) = \(fibonacci(n))"
        }

        // Simple arithmetic via NSExpression
        let sanitized = sanitizeExpression(expr)
        let nsExpr = NSExpression(format: sanitized)
        if let result = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber {
            return "\(expr) = \(result)"
        }

        throw ToolError.executionFailed("Could not evaluate: \(expr)")
    }

    private func extractInner(_ s: String) -> String {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")") else { return "" }
        return String(s[s.index(after: open)..<close])
    }

    private func factorial(_ n: Int) -> Int {
        if n <= 1 { return 1 }
        return n * factorial(n - 1)
    }

    private func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        if n == 2 { return true }
        if n % 2 == 0 { return false }
        for i in stride(from: 3, through: Int(Double(n).squareRoot()), by: 2) {
            if n % i == 0 { return false }
        }
        return true
    }

    private func fibonacci(_ n: Int) -> Int {
        if n <= 1 { return n }
        var a = 0, b = 1
        for _ in 2...n { (a, b) = (b, a + b) }
        return b
    }

    private func sanitizeExpression(_ expr: String) -> String {
        // Only allow digits, operators, parentheses, decimal point
        let allowed = CharacterSet.decimalDigits
            .union(.init(charactersIn: "+-*/().^ "))
        return String(expr.unicodeScalars.filter { allowed.contains($0) })
    }
}
