#if os(macOS)
import Foundation
import SQLite3

// MARK: - Trading Database (SQLite3 C-API)
// Persistente Trade-Logs, Daily Stats und Strategy-Versionen

public actor TradingDatabase {
    public static let shared = TradingDatabase()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoboldOS/trading")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dbPath = base.appendingPathComponent("trades.db").path
    }

    // MARK: - Open / Close

    public func open() throws {
        guard db == nil else { return }
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TradingError.database("SQLite open failed: \(msg)")
        }
        sqlite3_busy_timeout(db, 5000)
        try createTables()
    }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func ensureOpen() throws {
        if db == nil { try open() }
    }

    // MARK: - Schema

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS trades (
            id TEXT PRIMARY KEY,
            timestamp TEXT NOT NULL,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'MARKET',
            size REAL NOT NULL,
            price REAL NOT NULL,
            fee REAL NOT NULL DEFAULT 0,
            strategy TEXT NOT NULL,
            regime TEXT DEFAULT 'UNKNOWN',
            confidence REAL DEFAULT 0,
            exit_price REAL,
            pnl REAL,
            holding_time TEXT,
            status TEXT NOT NULL DEFAULT 'OPEN',
            order_id TEXT,
            notes TEXT
        );
        CREATE TABLE IF NOT EXISTS daily_stats (
            date TEXT PRIMARY KEY,
            total_trades INTEGER DEFAULT 0,
            wins INTEGER DEFAULT 0,
            losses INTEGER DEFAULT 0,
            gross_pnl REAL DEFAULT 0,
            fees REAL DEFAULT 0,
            net_pnl REAL DEFAULT 0,
            max_drawdown REAL DEFAULT 0,
            sharpe_ratio REAL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS strategy_versions (
            id TEXT PRIMARY KEY,
            strategy_name TEXT NOT NULL,
            version INTEGER NOT NULL,
            params TEXT NOT NULL,
            created_at TEXT NOT NULL,
            performance TEXT,
            is_active INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_trades_pair ON trades(pair);
        CREATE INDEX IF NOT EXISTS idx_trades_status ON trades(status);
        CREATE INDEX IF NOT EXISTS idx_trades_timestamp ON trades(timestamp);
        CREATE INDEX IF NOT EXISTS idx_trades_strategy ON trades(strategy);
        CREATE TABLE IF NOT EXISTS forecast_log (
            id TEXT PRIMARY KEY,
            timestamp TEXT NOT NULL,
            pair TEXT NOT NULL,
            horizon TEXT NOT NULL,
            direction TEXT NOT NULL,
            confidence REAL NOT NULL,
            current_price REAL NOT NULL,
            target_price REAL NOT NULL,
            regime TEXT NOT NULL,
            factors TEXT,
            actual_price REAL,
            actual_direction TEXT,
            was_correct INTEGER,
            error_pct REAL,
            validated_at TEXT,
            status TEXT NOT NULL DEFAULT 'PENDING'
        );
        CREATE INDEX IF NOT EXISTS idx_forecast_pair ON forecast_log(pair);
        CREATE INDEX IF NOT EXISTS idx_forecast_status ON forecast_log(status);
        CREATE INDEX IF NOT EXISTS idx_forecast_horizon ON forecast_log(horizon);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TradingError.database("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Trade CRUD

    public func logTrade(_ trade: TradeRecord) throws {
        try ensureOpen()
        let sql = """
        INSERT OR REPLACE INTO trades
        (id, timestamp, pair, side, type, size, price, fee, strategy, regime, confidence, status, order_id, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TradingError.database("Prepare logTrade failed")
        }
        sqlite3_bind_text(stmt, 1, trade.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, trade.timestamp, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, trade.pair, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, trade.side, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 5, trade.type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 6, trade.size)
        sqlite3_bind_double(stmt, 7, trade.price)
        sqlite3_bind_double(stmt, 8, trade.fee)
        sqlite3_bind_text(stmt, 9, trade.strategy, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 10, trade.regime, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 11, trade.confidence)
        sqlite3_bind_text(stmt, 12, trade.status, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let oid = trade.orderId {
            sqlite3_bind_text(stmt, 13, oid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else { sqlite3_bind_null(stmt, 13) }
        if let n = trade.notes {
            sqlite3_bind_text(stmt, 14, n, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else { sqlite3_bind_null(stmt, 14) }

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw TradingError.database("logTrade step failed")
        }
    }

    public func closeTrade(id: String, exitPrice: Double, pnl: Double, holdingTime: String) throws {
        try ensureOpen()
        let sql = "UPDATE trades SET status='CLOSED', exit_price=?, pnl=?, holding_time=? WHERE id=?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TradingError.database("Prepare closeTrade failed")
        }
        sqlite3_bind_double(stmt, 1, exitPrice)
        sqlite3_bind_double(stmt, 2, pnl)
        sqlite3_bind_text(stmt, 3, holdingTime, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw TradingError.database("closeTrade step failed")
        }
    }

    public func getOpenTrades() throws -> [TradeRecord] {
        try ensureOpen()
        return try queryTrades("SELECT * FROM trades WHERE status='OPEN' ORDER BY timestamp DESC")
    }

    public func getTradeHistory(limit: Int = 50) throws -> [TradeRecord] {
        try ensureOpen()
        return try queryTrades("SELECT * FROM trades ORDER BY timestamp DESC LIMIT \(limit)")
    }

    public func getClosedTrades(since: String? = nil) throws -> [TradeRecord] {
        try ensureOpen()
        if let since {
            // Parameterized Query (kein String-Interpolation → SQL Injection safe)
            let sql = "SELECT * FROM trades WHERE status='CLOSED' AND timestamp>=? ORDER BY timestamp ASC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, (since as NSString).utf8String, -1, nil)
            var trades: [TradeRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                trades.append(TradeRecord(
                    id: col(stmt, 0), timestamp: col(stmt, 1), pair: col(stmt, 2),
                    side: col(stmt, 3), type: col(stmt, 4),
                    size: sqlite3_column_double(stmt, 5), price: sqlite3_column_double(stmt, 6),
                    fee: sqlite3_column_double(stmt, 7), strategy: col(stmt, 8), regime: col(stmt, 9),
                    confidence: sqlite3_column_double(stmt, 10),
                    exitPrice: sqlite3_column_type(stmt, 11) != SQLITE_NULL ? sqlite3_column_double(stmt, 11) : nil,
                    pnl: sqlite3_column_type(stmt, 12) != SQLITE_NULL ? sqlite3_column_double(stmt, 12) : nil,
                    holdingTime: sqlite3_column_type(stmt, 13) != SQLITE_NULL ? col(stmt, 13) : nil,
                    status: col(stmt, 14),
                    orderId: sqlite3_column_type(stmt, 15) != SQLITE_NULL ? col(stmt, 15) : nil,
                    notes: sqlite3_column_type(stmt, 16) != SQLITE_NULL ? col(stmt, 16) : nil
                ))
            }
            return trades
        }
        return try queryTrades("SELECT * FROM trades WHERE status='CLOSED' ORDER BY timestamp ASC")
    }

    public func getTradeCount() throws -> Int {
        try ensureOpen()
        let sql = "SELECT COUNT(*) FROM trades"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func queryTrades(_ sql: String) throws -> [TradeRecord] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TradingError.database("Query failed: \(sql)")
        }
        var trades: [TradeRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            trades.append(TradeRecord(
                id: col(stmt, 0),
                timestamp: col(stmt, 1),
                pair: col(stmt, 2),
                side: col(stmt, 3),
                type: col(stmt, 4),
                size: sqlite3_column_double(stmt, 5),
                price: sqlite3_column_double(stmt, 6),
                fee: sqlite3_column_double(stmt, 7),
                strategy: col(stmt, 8),
                regime: col(stmt, 9),
                confidence: sqlite3_column_double(stmt, 10),
                exitPrice: sqlite3_column_type(stmt, 11) != SQLITE_NULL ? sqlite3_column_double(stmt, 11) : nil,
                pnl: sqlite3_column_type(stmt, 12) != SQLITE_NULL ? sqlite3_column_double(stmt, 12) : nil,
                holdingTime: sqlite3_column_type(stmt, 13) != SQLITE_NULL ? col(stmt, 13) : nil,
                status: col(stmt, 14),
                orderId: sqlite3_column_type(stmt, 15) != SQLITE_NULL ? col(stmt, 15) : nil,
                notes: sqlite3_column_type(stmt, 16) != SQLITE_NULL ? col(stmt, 16) : nil
            ))
        }
        return trades
    }

    private func col(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).flatMap { String(cString: $0) } ?? ""
    }

    // MARK: - Daily Stats

    public func updateDailyStats(date: String, stats: DailyTradingStats) throws {
        try ensureOpen()
        let sql = """
        INSERT OR REPLACE INTO daily_stats
        (date, total_trades, wins, losses, gross_pnl, fees, net_pnl, max_drawdown, sharpe_ratio)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, date, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(stats.totalTrades))
        sqlite3_bind_int(stmt, 3, Int32(stats.wins))
        sqlite3_bind_int(stmt, 4, Int32(stats.losses))
        sqlite3_bind_double(stmt, 5, stats.grossPnl)
        sqlite3_bind_double(stmt, 6, stats.fees)
        sqlite3_bind_double(stmt, 7, stats.netPnl)
        sqlite3_bind_double(stmt, 8, stats.maxDrawdown)
        sqlite3_bind_double(stmt, 9, stats.sharpeRatio)
        _ = sqlite3_step(stmt)
    }

    public func getDailyStats(days: Int = 30) throws -> [DailyTradingStats] {
        try ensureOpen()
        let sql = "SELECT * FROM daily_stats ORDER BY date DESC LIMIT \(days)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var results: [DailyTradingStats] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(DailyTradingStats(
                date: col(stmt, 0),
                totalTrades: Int(sqlite3_column_int(stmt, 1)),
                wins: Int(sqlite3_column_int(stmt, 2)),
                losses: Int(sqlite3_column_int(stmt, 3)),
                grossPnl: sqlite3_column_double(stmt, 4),
                fees: sqlite3_column_double(stmt, 5),
                netPnl: sqlite3_column_double(stmt, 6),
                maxDrawdown: sqlite3_column_double(stmt, 7),
                sharpeRatio: sqlite3_column_double(stmt, 8)
            ))
        }
        return results
    }

    // MARK: - Strategy Versions

    public func saveStrategyVersion(name: String, version: Int, params: String, performance: String? = nil) throws {
        try ensureOpen()
        let id = "\(name)_v\(version)"
        let now = ISO8601DateFormatter().string(from: Date())
        // Deactivate old versions
        let deactivate = "UPDATE strategy_versions SET is_active=0 WHERE strategy_name=?"
        var s1: OpaquePointer?
        sqlite3_prepare_v2(db, deactivate, -1, &s1, nil)
        sqlite3_bind_text(s1, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(s1)
        sqlite3_finalize(s1)
        // Insert new
        let sql = "INSERT OR REPLACE INTO strategy_versions (id, strategy_name, version, params, created_at, performance, is_active) VALUES (?,?,?,?,?,?,1)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 3, Int32(version))
        sqlite3_bind_text(stmt, 4, params, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 5, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let perf = performance {
            sqlite3_bind_text(stmt, 6, perf, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else { sqlite3_bind_null(stmt, 6) }
        _ = sqlite3_step(stmt)
    }

    public func getLatestStrategyVersion(name: String) throws -> (version: Int, params: String)? {
        try ensureOpen()
        let sql = "SELECT version, params FROM strategy_versions WHERE strategy_name=? AND is_active=1 LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (Int(sqlite3_column_int(stmt, 0)), col(stmt, 1))
    }

    // MARK: - Forecast Log

    public func logForecast(id: String, pair: String, horizon: String, direction: String,
                            confidence: Double, currentPrice: Double, targetPrice: Double,
                            regime: String, factors: String?) throws {
        try ensureOpen()
        let sql = """
        INSERT OR IGNORE INTO forecast_log
        (id, timestamp, pair, horizon, direction, confidence, current_price, target_price, regime, factors, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING')
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, t)
        sqlite3_bind_text(stmt, 2, now, -1, t)
        sqlite3_bind_text(stmt, 3, pair, -1, t)
        sqlite3_bind_text(stmt, 4, horizon, -1, t)
        sqlite3_bind_text(stmt, 5, direction, -1, t)
        sqlite3_bind_double(stmt, 6, confidence)
        sqlite3_bind_double(stmt, 7, currentPrice)
        sqlite3_bind_double(stmt, 8, targetPrice)
        sqlite3_bind_text(stmt, 9, regime, -1, t)
        if let f = factors { sqlite3_bind_text(stmt, 10, f, -1, t) }
        else { sqlite3_bind_null(stmt, 10) }
        _ = sqlite3_step(stmt)
    }

    /// Holt Forecasts die validiert werden koennen (aelter als Horizont)
    public func getPendingForecasts(maxAge: TimeInterval) throws -> [(id: String, pair: String, horizon: String, direction: String, confidence: Double, currentPrice: Double)] {
        try ensureOpen()
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-maxAge))
        let sql = "SELECT id, pair, horizon, direction, confidence, current_price FROM forecast_log WHERE status='PENDING' AND timestamp < ? LIMIT 50"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, cutoff, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var results: [(String, String, String, String, Double, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((col(stmt, 0), col(stmt, 1), col(stmt, 2), col(stmt, 3),
                           sqlite3_column_double(stmt, 4), sqlite3_column_double(stmt, 5)))
        }
        return results
    }

    /// Validiert einen Forecast mit dem echten Preis
    public func validateForecast(id: String, actualPrice: Double, forecastPrice: Double) throws {
        try ensureOpen()
        let changePct = forecastPrice > 0 ? ((actualPrice - forecastPrice) / forecastPrice) * 100 : 0
        let actualDir: String
        if changePct > 0.5 { actualDir = "UP" }
        else if changePct < -0.5 { actualDir = "DOWN" }
        else { actualDir = "SIDEWAYS" }

        let sql = "UPDATE forecast_log SET actual_price=?, actual_direction=?, was_correct=?, error_pct=?, validated_at=?, status='VALIDATED' WHERE id=?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        // Korrektheit: Lese Direction aus dem Forecast
        let dirSql = "SELECT direction FROM forecast_log WHERE id=?"
        var dirStmt: OpaquePointer?
        defer { sqlite3_finalize(dirStmt) }
        var forecastDir = ""
        if sqlite3_prepare_v2(db, dirSql, -1, &dirStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(dirStmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(dirStmt) == SQLITE_ROW { forecastDir = col(dirStmt, 0) }
        }
        let wasCorrect = forecastDir == actualDir ? 1 : 0

        let now = ISO8601DateFormatter().string(from: Date())
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(stmt, 1, actualPrice)
        sqlite3_bind_text(stmt, 2, actualDir, -1, t)
        sqlite3_bind_int(stmt, 3, Int32(wasCorrect))
        sqlite3_bind_double(stmt, 4, changePct)
        sqlite3_bind_text(stmt, 5, now, -1, t)
        sqlite3_bind_text(stmt, 6, id, -1, t)
        _ = sqlite3_step(stmt)
    }

    /// Forecast-Accuracy Stats (gefiltert nach Horizont, optional Pair)
    public func getForecastAccuracy(horizon: String? = nil, pair: String? = nil, days: Int = 7) throws -> (total: Int, correct: Int, accuracy: Double) {
        try ensureOpen()
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86400))
        var sql = "SELECT COUNT(*), SUM(CASE WHEN was_correct=1 THEN 1 ELSE 0 END) FROM forecast_log WHERE status='VALIDATED' AND timestamp > ?"
        var params: [String] = [cutoff]
        if let h = horizon { sql += " AND horizon=?"; params.append(h) }
        if let p = pair { sql += " AND pair=?"; params.append(p) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, t)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0) }
        let total = Int(sqlite3_column_int(stmt, 0))
        let correct = Int(sqlite3_column_int(stmt, 1))
        let accuracy = total > 0 ? Double(correct) / Double(total) : 0
        return (total, correct, accuracy)
    }

    /// Alte Forecasts aufraeuemen (aelter als 30 Tage)
    public func purgeForecastLog(olderThanDays: Int = 30) throws {
        try ensureOpen()
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(olderThanDays) * 86400))
        let sql = "DELETE FROM forecast_log WHERE timestamp < ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, cutoff, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = sqlite3_step(stmt)
    }

    // MARK: - Forecast Accuracy per Factor

    /// Berechnet Accuracy pro Faktor aus validierten Forecasts (für adaptive Gewichte).
    /// Parst die `factors`-Spalte als JSON-Array von FactorScore-Objekten.
    public func getForecastAccuracyByFactor(days: Int = 14) throws -> [String: (correct: Int, total: Int)] {
        try ensureOpen()
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let sql = "SELECT factors, was_correct FROM forecast_log WHERE status='VALIDATED' AND timestamp > ? AND factors IS NOT NULL"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        sqlite3_bind_text(stmt, 1, cutoff, -1, t)

        var results: [String: (correct: Int, total: Int)] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let factorsStr: String = col(stmt, 0)
            let wasCorrect = sqlite3_column_int(stmt, 1) == 1

            // Versuche JSON-Parsing (neue FactorScore-Format)
            if let data = factorsStr.data(using: .utf8),
               let scores = try? JSONDecoder().decode([FactorScore].self, from: data) {
                for score in scores {
                    var entry = results[score.name] ?? (correct: 0, total: 0)
                    entry.total += 1
                    if wasCorrect { entry.correct += 1 }
                    results[score.name] = entry
                }
            } else {
                // Fallback: alte Semicolon-Format ("RSI; MACD; Trend")
                let names = factorsStr.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                for name in names {
                    let key = mapFactorName(name)
                    var entry = results[key] ?? (correct: 0, total: 0)
                    entry.total += 1
                    if wasCorrect { entry.correct += 1 }
                    results[key] = entry
                }
            }
        }
        return results
    }

    /// Mappt menschenlesbare Faktornamen auf ForecastWeights-Keys
    private func mapFactorName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("rsi") && lower.contains("div") { return "rsiDivergence" }
        if lower.contains("rsi") { return "rsi" }
        if lower.contains("macd") { return "macd" }
        if lower.contains("trend") || lower.contains("ema") && lower.contains("slope") { return "trend" }
        if lower.contains("ema") && lower.contains("align") { return "emaAlignment" }
        if lower.contains("ema200") || lower.contains("200") { return "ema200Bias" }
        if lower.contains("bollinger") || lower.contains("bb") { return "bollingerBand" }
        if lower.contains("volume") || lower.contains("vol") { return "volume" }
        if lower.contains("linear") || lower.contains("regression") { return "linearRegression" }
        if lower.contains("support") || lower.contains("resist") { return "supportResistance" }
        if lower.contains("candle") || lower.contains("pattern") { return "candlePatterns" }
        if lower.contains("momentum") || lower.contains("mom") { return "momentum" }
        return name
    }

    // MARK: - Integrity Check

    public func verifyIntegrity() -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK else { return false }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return col(stmt, 0) == "ok"
    }
}

// MARK: - Models

public struct TradeRecord: Sendable, Codable, Identifiable {
    public let id: String
    public let timestamp: String
    public let pair: String
    public let side: String      // BUY / SELL
    public let type: String      // MARKET / LIMIT
    public let size: Double
    public let price: Double
    public let fee: Double
    public let strategy: String
    public let regime: String
    public let confidence: Double
    public var exitPrice: Double?
    public var pnl: Double?
    public var holdingTime: String?
    public let status: String    // OPEN / CLOSED / CANCELLED
    public let orderId: String?
    public let notes: String?

    public init(id: String = UUID().uuidString, timestamp: String = ISO8601DateFormatter().string(from: Date()),
                pair: String, side: String, type: String = "MARKET", size: Double, price: Double,
                fee: Double = 0, strategy: String, regime: String = "UNKNOWN", confidence: Double = 0,
                exitPrice: Double? = nil, pnl: Double? = nil, holdingTime: String? = nil,
                status: String = "OPEN", orderId: String? = nil, notes: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.pair = pair; self.side = side
        self.type = type; self.size = size; self.price = price; self.fee = fee
        self.strategy = strategy; self.regime = regime; self.confidence = confidence
        self.exitPrice = exitPrice; self.pnl = pnl; self.holdingTime = holdingTime
        self.status = status; self.orderId = orderId; self.notes = notes
    }
}

public struct DailyTradingStats: Sendable, Codable {
    public let date: String
    public let totalTrades: Int
    public let wins: Int
    public let losses: Int
    public let grossPnl: Double
    public let fees: Double
    public let netPnl: Double
    public let maxDrawdown: Double
    public let sharpeRatio: Double

    public init(date: String = "", totalTrades: Int = 0, wins: Int = 0, losses: Int = 0,
                grossPnl: Double = 0, fees: Double = 0, netPnl: Double = 0,
                maxDrawdown: Double = 0, sharpeRatio: Double = 0) {
        self.date = date; self.totalTrades = totalTrades; self.wins = wins; self.losses = losses
        self.grossPnl = grossPnl; self.fees = fees; self.netPnl = netPnl
        self.maxDrawdown = maxDrawdown; self.sharpeRatio = sharpeRatio
    }
}

// MARK: - Errors

public enum TradingError: Error, LocalizedError {
    case database(String)
    case api(String)
    case riskViolation(String)
    case strategy(String)
    case config(String)

    public var errorDescription: String? {
        switch self {
        case .database(let m): return "Trading DB: \(m)"
        case .api(let m): return "Trading API: \(m)"
        case .riskViolation(let m): return "Risk: \(m)"
        case .strategy(let m): return "Strategy: \(m)"
        case .config(let m): return "Config: \(m)"
        }
    }
}
#endif
