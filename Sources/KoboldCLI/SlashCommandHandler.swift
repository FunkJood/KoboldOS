import Foundation

// MARK: - SlashCommandHandler
// Handles in-session slash commands for the interactive REPL.

struct SlashCommandHandler {

    let client: DaemonClient
    let sessionManager: CLISessionManager

    /// Returns true if the command was handled (caller should continue REPL).
    /// Returns false if REPL should exit.
    func handle(_ input: String) async -> Bool {
        let parts = input.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
        let command = parts[0].lowercased()
        let args = Array(parts.dropFirst())

        switch command {
        case "/help":
            printHelp()
            return true

        case "/quit", "/exit", "/q":
            await sessionManager.saveSession()
            print(TerminalFormatter.info("Session gespeichert. Auf Wiedersehen!"))
            return false

        case "/new":
            let session = await sessionManager.newSession()
            try? await client.post("/history/clear", body: [:])
            print(TerminalFormatter.success("Neue Session gestartet: \(session.id)"))
            return true

        case "/list", "/sessions":
            let sessions = await sessionManager.listSessions()
            if sessions.isEmpty {
                print(TerminalFormatter.info("Keine Sessions gespeichert."))
            } else {
                let headers = ["ID", "Titel", "Datum", "Nachrichten"]
                let rows = sessions.map { [$0.id, String($0.title.prefix(30)), $0.date, "\($0.count)"] }
                print(TerminalFormatter.table(headers: headers, rows: rows))
            }
            return true

        case "/load":
            guard let id = args.first else {
                print(TerminalFormatter.error("Nutzung: /load <session-id>"))
                return true
            }
            if let session = await sessionManager.loadSession(id: id) {
                print(TerminalFormatter.success("Session '\(session.title)' geladen (\(session.messageCount) Nachrichten)"))
            } else {
                print(TerminalFormatter.error("Session '\(id)' nicht gefunden"))
            }
            return true

        case "/delete":
            guard let id = args.first else {
                print(TerminalFormatter.error("Nutzung: /delete <session-id>"))
                return true
            }
            await sessionManager.deleteSession(id: id)
            print(TerminalFormatter.success("Session '\(id)' gelöscht"))
            return true

        case "/clear":
            await sessionManager.clearCurrentSession()
            try? await client.post("/history/clear", body: [:])
            print(TerminalFormatter.success("Session geleert"))
            return true

        case "/model":
            if let name = args.first {
                do {
                    let _ = try await client.post("/model/set", body: ["model": name])
                    print(TerminalFormatter.success("Modell gewechselt: \(name)"))
                } catch {
                    print(TerminalFormatter.error("Fehler: \(error.localizedDescription)"))
                }
            } else {
                do {
                    let result = try await client.get("/models")
                    let active = result["active"] as? String ?? "unbekannt"
                    let status = result["ollama_status"] as? String ?? "?"
                    print(TerminalFormatter.info("Aktives Modell: \(active) (Ollama: \(status))"))
                } catch {
                    print(TerminalFormatter.error("Fehler: \(error.localizedDescription)"))
                }
            }
            return true

        case "/agent":
            if let type = args.first {
                print(TerminalFormatter.success("Agent-Typ: \(type)"))
            } else {
                print(TerminalFormatter.info("Verfügbare Typen: general, coder, researcher, planner, instructor"))
            }
            return true

        case "/memory":
            do {
                let result = try await client.get("/memory")
                if let blocks = result["blocks"] as? [[String: Any]] {
                    let headers = ["Label", "Zeichen", "Limit", "%"]
                    let rows: [[String]] = blocks.map { b in
                        let label = b["label"] as? String ?? "?"
                        let content = b["content"] as? String ?? ""
                        let limit = b["limit"] as? Int ?? 0
                        let pct = limit > 0 ? Int(Double(content.count) / Double(limit) * 100) : 0
                        return [label, "\(content.count)", "\(limit)", "\(pct)%"]
                    }
                    print(TerminalFormatter.table(headers: headers, rows: rows))
                }
            } catch {
                print(TerminalFormatter.error("Fehler: \(error.localizedDescription)"))
            }
            return true

        case "/export":
            let path = args.first
            if let result = await sessionManager.exportMarkdown(path: path) {
                if path != nil {
                    print(TerminalFormatter.success("Exportiert nach: \(result)"))
                } else {
                    print(result)
                }
            } else {
                print(TerminalFormatter.error("Keine aktive Session"))
            }
            return true

        case "/resume":
            do {
                if let id = args.first {
                    let result = try await client.post("/checkpoints/resume", body: ["id": id])
                    print(TerminalFormatter.success("Checkpoint '\(id)' fortgesetzt"))
                } else {
                    let result = try await client.get("/checkpoints")
                    if let cps = result["checkpoints"] as? [[String: Any]] {
                        if cps.isEmpty {
                            print(TerminalFormatter.info("Keine Checkpoints vorhanden"))
                        } else {
                            let headers = ["ID", "Typ", "Schritte", "Status", "Nachricht"]
                            let rows = cps.map { cp -> [String] in
                                [
                                    cp["id"] as? String ?? "?",
                                    cp["agentType"] as? String ?? "?",
                                    "\(cp["stepCount"] as? Int ?? 0)",
                                    cp["status"] as? String ?? "?",
                                    String((cp["userMessage"] as? String ?? "").prefix(30))
                                ]
                            }
                            print(TerminalFormatter.table(headers: headers, rows: rows))
                        }
                    }
                }
            } catch {
                print(TerminalFormatter.error("Fehler: \(error.localizedDescription)"))
            }
            return true

        default:
            print(TerminalFormatter.error("Unbekannter Befehl: \(command). Tippe /help für Hilfe."))
            return true
        }
    }

    // MARK: - Help

    private func printHelp() {
        let commands = """

        Verfügbare Befehle:

          /help              Dieses Hilfemenü anzeigen
          /quit              Session speichern und beenden
          /new               Neue Chat-Session starten
          /list              Alle gespeicherten Sessions anzeigen
          /load <id>         Session laden
          /delete <id>       Session löschen
          /clear             Aktuelle Session leeren
          /model [name]      Aktives Modell anzeigen/wechseln
          /agent [type]      Agent-Typ anzeigen/wechseln
          /memory            Memory-Blöcke anzeigen
          /export [pfad]     Session als Markdown exportieren
          /resume [id]       Checkpoint fortsetzen

        """
        print(TerminalFormatter.info(commands))
    }
}
