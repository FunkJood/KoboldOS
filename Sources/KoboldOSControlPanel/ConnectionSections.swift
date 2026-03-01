import SwiftUI
import WebKit
import KoboldCore

// MARK: - Connection Sections (Extension auf SettingsView)
// 12 neue Verbindungs-Sektionen für Phase-1 Services

extension SettingsView {

    // MARK: - GitHub

    @ViewBuilder
    func githubConnectionSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoGitHub),
            name: "GitHub",
            subtitle: "Repos, Issues, Pull Requests",
            isConnected: GitHubOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.fill").foregroundColor(.secondary)
                        Text(GitHubOAuth.shared.userName).font(.system(size: 13))
                    }
                    Button("Abmelden") { Task { await GitHubOAuth.shared.signOut() } }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Client-Konfiguration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client ID").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("GitHub OAuth Client ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.github.clientId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.github.clientId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("Client Secret").font(.system(size: 11)).foregroundColor(.secondary)
                            SecureField("GitHub OAuth Client Secret", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.github.clientSecret") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.github.clientSecret") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12.5))

                    Button(action: { GitHubOAuth.shared.signIn() }) {
                        Label("Mit GitHub anmelden", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)
                })
            }
        )
    }

    // MARK: - Microsoft

    @ViewBuilder
    func microsoftConnectionSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoMicrosoft),
            name: "Microsoft",
            subtitle: "OneDrive, Outlook, Calendar, Teams",
            isConnected: MicrosoftOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.fill").foregroundColor(.secondary)
                        Text(MicrosoftOAuth.shared.userName).font(.system(size: 13))
                    }
                    Button("Abmelden") { Task { await MicrosoftOAuth.shared.signOut() } }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Client-Konfiguration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Application (Client) ID").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("Microsoft App Client ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.microsoft.clientId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.microsoft.clientId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("Client Secret").font(.system(size: 11)).foregroundColor(.secondary)
                            SecureField("Microsoft Client Secret", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.microsoft.clientSecret") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.microsoft.clientSecret") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12.5))

                    Button(action: { MicrosoftOAuth.shared.signIn() }) {
                        Label("Mit Microsoft anmelden", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                })
            }
        )
    }

    // MARK: - Slack

    @ViewBuilder
    func slackConnectionSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoSlack),
            name: "Slack",
            subtitle: "Kanäle, Nachrichten, Benutzer",
            isConnected: SlackOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.fill").foregroundColor(.secondary)
                        Text(SlackOAuth.shared.userName).font(.system(size: 13))
                    }
                    Button("Abmelden") { Task { await SlackOAuth.shared.signOut() } }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Client-Konfiguration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client ID").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("Slack App Client ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.slack.clientId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.slack.clientId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("Client Secret").font(.system(size: 11)).foregroundColor(.secondary)
                            SecureField("Slack App Client Secret", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.slack.clientSecret") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.slack.clientSecret") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12.5))

                    Button(action: { SlackOAuth.shared.signIn() }) {
                        Label("Mit Slack anmelden", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                })
            }
        )
    }

    // MARK: - Notion

    @ViewBuilder
    func notionConnectionSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoNotion),
            name: "Notion",
            subtitle: "Seiten, Datenbanken, Suche",
            isConnected: NotionOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.fill").foregroundColor(.secondary)
                        Text(NotionOAuth.shared.userName).font(.system(size: 13))
                    }
                    Button("Abmelden") { Task { await NotionOAuth.shared.signOut() } }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Client-Konfiguration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("OAuth Client ID").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("Notion Integration Client ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.notion.clientId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.notion.clientId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("OAuth Client Secret").font(.system(size: 11)).foregroundColor(.secondary)
                            SecureField("Notion Integration Secret", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.notion.clientSecret") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.notion.clientSecret") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12.5))

                    Button(action: { NotionOAuth.shared.signIn() }) {
                        Label("Mit Notion verbinden", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.primary)
                })
            }
        )
    }

    // MARK: - WhatsApp

    @ViewBuilder
    func whatsappConnectionSection() -> some View {
        let webLinked = UserDefaults.standard.bool(forKey: "kobold.whatsapp.webLinked")
        connectionCard(
            logo: AnyView(Image(systemName: "phone.bubble.fill").font(.title2).foregroundColor(.green)),
            name: "WhatsApp",
            subtitle: "Web-Verknüpfung",
            isConnected: webLinked || WhatsAppOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    if webLinked {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                            Text("WhatsApp Web verknüpft").font(.system(size: 13))
                        }
                        Button("WhatsApp Web öffnen") {
                            whatsappShowWebView = true
                        }
                        .font(.system(size: 12)).foregroundColor(.koboldEmerald)
                    }
                    if WhatsAppOAuth.shared.isConnected {
                        HStack(spacing: 6) {
                            Image(systemName: "server.rack").foregroundColor(.secondary)
                            Text("Business API: \(WhatsAppOAuth.shared.userName)").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        if webLinked {
                            Button("Web trennen") {
                                UserDefaults.standard.set(false, forKey: "kobold.whatsapp.webLinked")
                                // Clear WhatsApp Web cookies
                                let dataStore = WKWebsiteDataStore.default()
                                dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                                    let whatsappRecords = records.filter { $0.displayName.contains("whatsapp") }
                                    dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: whatsappRecords) {}
                                }
                            }
                            .font(.system(size: 12)).foregroundColor(.red)
                        }
                        if WhatsAppOAuth.shared.isConnected {
                            Button("API abmelden") { Task { await WhatsAppOAuth.shared.signOut() } }
                                .font(.system(size: 12)).foregroundColor(.red)
                        }
                    }
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 12) {
                    // WhatsApp Web linking (primary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scanne den QR-Code mit deinem Handy um WhatsApp Web zu verknüpfen — genau wie auf web.whatsapp.com.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: { whatsappShowWebView = true }) {
                            Label("WhatsApp Web verknüpfen", systemImage: "qrcode")
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                    }

                    // Optional: Business API (advanced)
                    DisclosureGroup("Business API (optional)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Für programmatischen Zugriff via Meta Business API.")
                                .font(.system(size: 11)).foregroundColor(.secondary)

                            Text("App ID").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 4)
                            TextField("Meta App ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.whatsapp.clientId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.whatsapp.clientId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("App Secret").font(.system(size: 11)).foregroundColor(.secondary)
                            SecureField("Meta App Secret", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.whatsapp.clientSecret") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.whatsapp.clientSecret") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("Phone Number ID").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("Phone Number ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.whatsapp.phoneNumberId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.whatsapp.phoneNumberId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Button(action: { WhatsAppOAuth.shared.signIn() }) {
                                Label("Business API verbinden", systemImage: "arrow.right.circle.fill")
                            }
                            .buttonStyle(.bordered).tint(.green)
                            .disabled((UserDefaults.standard.string(forKey: "kobold.whatsapp.clientId") ?? "").isEmpty)
                        }
                    }.font(.system(size: 12.5))
                })
            }
        )
        .sheet(isPresented: $whatsappShowWebView) {
            WhatsAppWebSheet()
        }
    }

    /// Generate QR code as NSImage (reusable for any connection)
    func generateConnectionQR(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - HuggingFace (Token-basiert)

    @ViewBuilder
    func huggingFaceConnectionSection() -> some View {
        let isConnected = !(UserDefaults.standard.string(forKey: "kobold.huggingface.apiToken") ?? "").isEmpty
        connectionCard(
            logo: AnyView(brandLogoHuggingFace),
            name: "Hugging Face",
            subtitle: "AI-Inference, Modelle",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text("API-Token konfiguriert").font(.system(size: 13))
                    }
                    Button("Token entfernen") {
                        UserDefaults.standard.removeObject(forKey: "kobold.huggingface.apiToken")
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("API-Token von huggingface.co/settings/tokens").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("HuggingFace API Token", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.huggingface.apiToken") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.huggingface.apiToken") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                })
            }
        )
    }

    // MARK: - Twilio (AccountSID + AuthToken)

    @ViewBuilder
    func twilioConnectionSection() -> some View {
        let isConnected = !(UserDefaults.standard.string(forKey: "kobold.twilio.accountSid") ?? "").isEmpty
            && !(UserDefaults.standard.string(forKey: "kobold.twilio.authToken") ?? "").isEmpty
        connectionCard(
            logo: AnyView(Image(systemName: "phone.fill").font(.title2).foregroundColor(.red)),
            name: "Twilio (SMS & Telefonie)",
            subtitle: "SMS + Anrufe via Twilio",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text("Twilio konfiguriert").font(.system(size: 13))
                    }
                    HStack {
                        Text("Von:").font(.system(size: 11)).foregroundColor(.secondary)
                        TextField("+1...", text: Binding(
                            get: { UserDefaults.standard.string(forKey: "kobold.twilio.fromNumber") ?? "" },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.twilio.fromNumber") }
                        )).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 180)
                    }

                    Divider()

                    // Telefonie & eingehende SMS
                    Text("Telefonie & Eingehende SMS").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)

                    Text("Öffentliche URL (automatisch via Cloudflare Tunnel)").font(.system(size: 10)).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        TextField("Automatisch via Cloudflare Tunnel", text: Binding(
                            get: { UserDefaults.standard.string(forKey: "kobold.twilio.publicUrl") ?? "" },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.twilio.publicUrl") }
                        )).textFieldStyle(.roundedBorder).font(.system(size: 11))
                        // Status-Indikator
                        if !(UserDefaults.standard.string(forKey: "kobold.twilio.publicUrl") ?? "").isEmpty {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald).font(.system(size: 12))
                        }
                    }
                    Text("Wird automatisch gesetzt wenn Cloudflare Tunnel aktiv ist (Einstellungen → WebApp-Server)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))

                    // Twilio-Webhook-Konfigurationshinweis
                    let pubUrl = UserDefaults.standard.string(forKey: "kobold.twilio.publicUrl") ?? ""
                    if !pubUrl.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Twilio-Konsole Einrichtung (für eingehende Anrufe/SMS):").font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
                            HStack(spacing: 4) {
                                Text("Voice-URL:").font(.system(size: 9)).foregroundColor(.secondary)
                                Text("\(pubUrl)/twilio/voice/webhook").font(.system(size: 9, design: .monospaced)).foregroundColor(.primary).textSelection(.enabled)
                            }
                            HStack(spacing: 4) {
                                Text("SMS-URL:").font(.system(size: 9)).foregroundColor(.secondary)
                                Text("\(pubUrl)/twilio/sms/webhook").font(.system(size: 9, design: .monospaced)).foregroundColor(.primary).textSelection(.enabled)
                            }
                            Text("→ Twilio Console → Phone Numbers → Nummer wählen → Voice/Messaging → Webhook-URL eintragen (HTTP POST)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.06))
                        .cornerRadius(6)
                    }

                    Text("Nummern-Whitelist (E.164, eine pro Zeile)").font(.system(size: 10)).foregroundColor(.secondary)
                    TextEditor(text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.twilio.whitelist") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.twilio.whitelist") }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                    Button("Zugangsdaten entfernen") {
                        for k in ["kobold.twilio.accountSid", "kobold.twilio.authToken", "kobold.twilio.fromNumber",
                                   "kobold.twilio.publicUrl", "kobold.twilio.whitelist"] {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("Account SID").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("ACxxxxxxxx", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.twilio.accountSid") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.twilio.accountSid") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Auth Token").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Twilio Auth Token", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.twilio.authToken") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.twilio.authToken") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Absender-Nummer").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("+1234567890", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.twilio.fromNumber") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.twilio.fromNumber") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                })
            }
        )
    }

    // MARK: - E-Mail (SMTP/IMAP)

    @ViewBuilder
    func emailConnectionSection() -> some View {
        let isConnected = !(UserDefaults.standard.string(forKey: "kobold.email.address") ?? "").isEmpty
            && !(UserDefaults.standard.string(forKey: "kobold.email.password") ?? "").isEmpty
        connectionCard(
            logo: AnyView(Image(systemName: "envelope.fill").font(.title2).foregroundColor(.blue)),
            name: "E-Mail",
            subtitle: "SMTP/IMAP",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text(UserDefaults.standard.string(forKey: "kobold.email.address") ?? "").font(.system(size: 13))
                    }
                    Button("Zugangsdaten entfernen") {
                        for k in ["kobold.email.address", "kobold.email.password", "kobold.email.smtpHost", "kobold.email.smtpPort", "kobold.email.imapHost", "kobold.email.imapPort"] {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("E-Mail-Adresse").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("user@example.com", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.email.address") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.email.address") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Passwort / App-Passwort").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Passwort", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.email.password") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.email.password") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    DisclosureGroup("Server-Einstellungen") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("SMTP Host").font(.system(size: 10)).foregroundColor(.secondary)
                                    TextField("smtp.gmail.com", text: Binding(
                                        get: { UserDefaults.standard.string(forKey: "kobold.email.smtpHost") ?? "smtp.gmail.com" },
                                        set: { UserDefaults.standard.set($0, forKey: "kobold.email.smtpHost") }
                                    )).textFieldStyle(.roundedBorder).font(.system(size: 11))
                                }
                                VStack(alignment: .leading) {
                                    Text("Port").font(.system(size: 10)).foregroundColor(.secondary)
                                    TextField("587", text: Binding(
                                        get: { UserDefaults.standard.string(forKey: "kobold.email.smtpPort") ?? "587" },
                                        set: { UserDefaults.standard.set($0, forKey: "kobold.email.smtpPort") }
                                    )).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 60)
                                }
                            }
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("IMAP Host").font(.system(size: 10)).foregroundColor(.secondary)
                                    TextField("imap.gmail.com", text: Binding(
                                        get: { UserDefaults.standard.string(forKey: "kobold.email.imapHost") ?? "imap.gmail.com" },
                                        set: { UserDefaults.standard.set($0, forKey: "kobold.email.imapHost") }
                                    )).textFieldStyle(.roundedBorder).font(.system(size: 11))
                                }
                                VStack(alignment: .leading) {
                                    Text("Port").font(.system(size: 10)).foregroundColor(.secondary)
                                    TextField("993", text: Binding(
                                        get: { UserDefaults.standard.string(forKey: "kobold.email.imapPort") ?? "993" },
                                        set: { UserDefaults.standard.set($0, forKey: "kobold.email.imapPort") }
                                    )).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 60)
                                }
                            }
                        }
                    }.font(.system(size: 12))
                })
            }
        )
    }

    // MARK: - Webhook

    @ViewBuilder
    func webhookConnectionSection() -> some View {
        let isRunning = WebhookServer.shared.isRunning
        connectionCard(
            logo: AnyView(Image(systemName: "antenna.radiowaves.left.and.right").font(.title2).foregroundColor(.orange)),
            name: "Webhook",
            subtitle: "HTTP Webhooks",
            isConnected: isRunning,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.circle.fill").foregroundColor(.koboldEmerald)
                        Text("Server läuft auf Port \(WebhookServer.shared.port)").font(.system(size: 13))
                    }
                    Text("Pfade: \(WebhookServer.shared.registeredPaths.joined(separator: ", "))").font(.system(size: 11)).foregroundColor(.secondary)
                    Button("Server stoppen") { WebhookServer.shared.stop() }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("Starte einen lokalen Webhook-Server für eingehende HTTP-Requests.").font(.system(size: 11)).foregroundColor(.secondary)

                    HStack {
                        Text("Port:").font(.system(size: 11)).foregroundColor(.secondary)
                        TextField("8089", text: Binding(
                            get: { String(UserDefaults.standard.integer(forKey: "kobold.webhook.port") > 0 ? UserDefaults.standard.integer(forKey: "kobold.webhook.port") : 8089) },
                            set: { UserDefaults.standard.set(Int($0) ?? 8089, forKey: "kobold.webhook.port") }
                        )).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 80)
                    }

                    Button(action: { _ = WebhookServer.shared.start() }) {
                        Label("Webhook-Server starten", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                })
            }
        )
    }

    // MARK: - CalDAV

    @ViewBuilder
    func caldavConnectionSection() -> some View {
        let isConnected = !(UserDefaults.standard.string(forKey: "kobold.caldav.serverURL") ?? "").isEmpty
            && !(UserDefaults.standard.string(forKey: "kobold.caldav.username") ?? "").isEmpty
        connectionCard(
            logo: AnyView(Image(systemName: "calendar").font(.title2).foregroundColor(.red)),
            name: "CalDAV",
            subtitle: "Kalender synchronisieren",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text(UserDefaults.standard.string(forKey: "kobold.caldav.serverURL") ?? "").font(.system(size: 12)).lineLimit(1)
                    }
                    Button("Zugangsdaten entfernen") {
                        for k in ["kobold.caldav.serverURL", "kobold.caldav.username", "kobold.caldav.password"] {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("https://caldav.example.com/dav/", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.caldav.serverURL") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.caldav.serverURL") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Benutzername").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("user", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.caldav.username") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.caldav.username") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Passwort").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Passwort", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.caldav.password") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.caldav.password") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                })
            }
        )
    }

    // MARK: - MQTT

    @ViewBuilder
    func mqttConnectionSection() -> some View {
        let isConnected = !(UserDefaults.standard.string(forKey: "kobold.mqtt.host") ?? "").isEmpty
        connectionCard(
            logo: AnyView(Image(systemName: "sensor.fill").font(.title2).foregroundColor(.teal)),
            name: "MQTT",
            subtitle: "IoT / Smart Home",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text("\(UserDefaults.standard.string(forKey: "kobold.mqtt.host") ?? ""):\(UserDefaults.standard.string(forKey: "kobold.mqtt.port") ?? "1883")").font(.system(size: 13))
                    }
                    Button("Konfiguration entfernen") {
                        for k in ["kobold.mqtt.host", "kobold.mqtt.port", "kobold.mqtt.username", "kobold.mqtt.password"] {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("MQTT Broker").font(.system(size: 11)).foregroundColor(.secondary)
                    HStack {
                        TextField("broker.example.com", text: Binding(
                            get: { UserDefaults.standard.string(forKey: "kobold.mqtt.host") ?? "" },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.mqtt.host") }
                        )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        TextField("1883", text: Binding(
                            get: { UserDefaults.standard.string(forKey: "kobold.mqtt.port") ?? "1883" },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.mqtt.port") }
                        )).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 70)
                    }

                    DisclosureGroup("Authentifizierung (optional)") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Benutzername", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.mqtt.username") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.mqtt.username") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                            SecureField("Passwort", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.mqtt.password") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.mqtt.password") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12))
                })
            }
        )
    }

    // MARK: - RSS

    @ViewBuilder
    func rssConnectionSection() -> some View {
        let feeds = UserDefaults.standard.stringArray(forKey: "kobold.rss.feeds") ?? []
        let isConnected = !feeds.isEmpty
        connectionCard(
            logo: AnyView(Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundColor(.orange)),
            name: "RSS",
            subtitle: "Feeds abonnieren",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("\(feeds.count) Feed(s) abonniert").font(.system(size: 13))
                    ForEach(feeds.prefix(5), id: \.self) { feed in
                        Text(feed).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                    if feeds.count > 5 {
                        Text("... und \(feeds.count - 5) weitere").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Button("Alle Feeds entfernen") {
                        UserDefaults.standard.removeObject(forKey: "kobold.rss.feeds")
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("Füge RSS/Atom Feed-URLs hinzu. Der Agent kann dann Feeds abrufen und lesen.").font(.system(size: 11)).foregroundColor(.secondary)
                    Text("Feeds können auch per Chat hinzugefügt werden: \"Füge den RSS-Feed von xyz.com hinzu\"").font(.system(size: 11)).foregroundColor(.secondary).italic()
                })
            }
        )
    }

    // MARK: - Lieferando

    internal var brandLogoLieferando: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange)
                .frame(width: 32, height: 32)
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    func lieferandoConnectionSection() -> some View {
        let hasApiKey = !(UserDefaults.standard.string(forKey: "kobold.lieferando.apiKey") ?? "").isEmpty
        let hasPostalCode = !(UserDefaults.standard.string(forKey: "kobold.lieferando.postalCode") ?? "").isEmpty

        connectionCard(
            logo: AnyView(brandLogoLieferando),
            name: "Lieferando",
            subtitle: "Restaurants, Bestellungen",
            isConnected: hasApiKey || hasPostalCode,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 6) {
                    let plz = UserDefaults.standard.string(forKey: "kobold.lieferando.postalCode") ?? ""
                    if !plz.isEmpty {
                        HStack {
                            Image(systemName: "location.fill").foregroundColor(.secondary)
                            Text("PLZ: \(plz)").font(.system(size: 12))
                        }
                    }
                    Button("Zurücksetzen") {
                        UserDefaults.standard.removeObject(forKey: "kobold.lieferando.apiKey")
                        UserDefaults.standard.removeObject(forKey: "kobold.lieferando.postalCode")
                        UserDefaults.standard.removeObject(forKey: "kobold.lieferando.address")
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("Postleitzahl").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("z.B. 10115", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.lieferando.postalCode") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.lieferando.postalCode") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Lieferadresse (optional)").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("Straße, Hausnummer", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.lieferando.address") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.lieferando.address") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("API-Key (optional, für erweiterte Features)").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Takeaway API Key", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.lieferando.apiKey") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.lieferando.apiKey") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Ohne API-Key kann der Agent trotzdem Restaurants durchsuchen. Für Bestellstatus wird ein API-Key benötigt.")
                        .font(.system(size: 10)).foregroundColor(.secondary).italic()
                })
            }
        )
    }

    // MARK: - Uber

    internal var brandLogoUber: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
                .frame(width: 32, height: 32)
            Text("U")
                .font(.system(size: 18, weight: .heavy, design: .default))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    func uberConnectionSection() -> some View {
        let isConnected = !(UserDefaults.standard.string(forKey: "kobold.uber.accessToken") ?? "").isEmpty

        connectionCard(
            logo: AnyView(brandLogoUber),
            name: "Uber",
            subtitle: "Fahrten, Preisschätzung",
            isConnected: isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "car.fill").foregroundColor(.secondary)
                        Text("Verbunden").font(.system(size: 12))
                    }
                    Button("Abmelden") {
                        UserDefaults.standard.removeObject(forKey: "kobold.uber.accessToken")
                        UserDefaults.standard.removeObject(forKey: "kobold.uber.clientId")
                        UserDefaults.standard.removeObject(forKey: "kobold.uber.clientSecret")
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("Uber OAuth-Konfiguration").font(.system(size: 12, weight: .semibold))

                    Text("Client ID").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("Uber Client ID", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.uber.clientId") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.uber.clientId") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Client Secret").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Uber Client Secret", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.uber.clientSecret") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.uber.clientSecret") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Access Token (aus OAuth-Flow oder manuell)").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Bearer Token", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.uber.accessToken") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.uber.accessToken") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Erstelle eine App unter developer.uber.com und trage die Credentials ein. Der Agent kann dann Fahrpreise schätzen und Fahrten buchen.")
                        .font(.system(size: 10)).foregroundColor(.secondary).italic()
                })
            }
        )
    }

    // MARK: - Suno AI (API-Key basiert)

    internal var brandLogoSuno: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color.purple, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    func sunoConnectionSection() -> some View {
        let hasApiKey = !(UserDefaults.standard.string(forKey: "kobold.suno.apiKey") ?? "").isEmpty
        connectionCard(
            logo: AnyView(brandLogoSuno),
            name: "Suno AI",
            subtitle: "Musik generieren",
            isConnected: hasApiKey,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text("API-Key konfiguriert").font(.system(size: 13))
                    }
                    Text("Der Agent kann Songs aus Textbeschreibungen generieren.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Button("API-Key entfernen") {
                        UserDefaults.standard.removeObject(forKey: "kobold.suno.apiKey")
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("API-Key von sunoapi.org").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("Suno API Key", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.suno.apiKey") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.suno.apiKey") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Erstelle einen Account auf sunoapi.org und kopiere deinen API-Key hierher. Der Agent kann dann Musik generieren.")
                        .font(.system(size: 10)).foregroundColor(.secondary).italic()
                })
            }
        )
    }

    // MARK: - ElevenLabs ConvAI

    internal var brandLogoElevenLabs: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color.purple, Color(red: 0.4, green: 0.1, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    func elevenLabsConnectionSection() -> some View {
        let apiKey = UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? ""
        let agentId = UserDefaults.standard.string(forKey: "kobold.elevenlabs.convai.agentId") ?? ""
        let hasConnection = !apiKey.isEmpty
        connectionCard(
            logo: AnyView(brandLogoElevenLabs),
            name: "ElevenLabs",
            subtitle: "Stimme & Live-Gespräche",
            isConnected: hasConnection,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.koboldEmerald)
                        Text("API-Key konfiguriert").font(.system(size: 13))
                    }
                    if !agentId.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "person.wave.2.fill").foregroundColor(.purple)
                            Text("Agent: \(agentId.prefix(12))...").font(.system(size: 12, design: .monospaced))
                        }
                    }
                    if UserDefaults.standard.bool(forKey: "kobold.elevenlabs.convai.customLLM") {
                        HStack(spacing: 4) {
                            Image(systemName: "brain.head.profile").foregroundColor(.purple).font(.system(size: 11))
                            Text("Custom LLM aktiv").font(.system(size: 11, weight: .medium)).foregroundColor(.purple)
                        }
                    }
                    Text("TTS, Live-Voice und Telefonie über ElevenLabs.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Button("API-Key entfernen") {
                        UserDefaults.standard.removeObject(forKey: "kobold.elevenlabs.apiKey")
                    }
                    .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    Text("API-Key von elevenlabs.io").font(.system(size: 11)).foregroundColor(.secondary)
                    SecureField("ElevenLabs API Key", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.elevenlabs.apiKey") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    TextField("Agent-ID (für ConvAI)", text: Binding(
                        get: { UserDefaults.standard.string(forKey: "kobold.elevenlabs.convai.agentId") ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: "kobold.elevenlabs.convai.agentId") }
                    )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                    Text("Erstelle einen Account auf elevenlabs.io und kopiere deinen API-Key. Für Live-Voice erstelle zusätzlich einen ConvAI Agent.")
                        .font(.system(size: 10)).foregroundColor(.secondary).italic()
                })
            }
        )
    }

    // MARK: - Reddit

    internal var brandLogoReddit: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange)
                .frame(width: 32, height: 32)
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    func redditConnectionSection() -> some View {
        connectionCard(
            logo: AnyView(brandLogoReddit),
            name: "Reddit",
            subtitle: "Posts, Subreddits, Kommentare",
            isConnected: RedditOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.fill").foregroundColor(.secondary)
                        Text(RedditOAuth.shared.userName).font(.system(size: 13))
                    }
                    Button("Abmelden") { Task { await RedditOAuth.shared.signOut() } }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Reddit App-Konfiguration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client ID (unter reddit.com/prefs/apps)").font(.system(size: 11)).foregroundColor(.secondary)
                            TextField("Reddit App Client ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.reddit.clientId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.reddit.clientId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))

                            Text("Client Secret").font(.system(size: 11)).foregroundColor(.secondary)
                            SecureField("Reddit App Secret", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.reddit.clientSecret") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.reddit.clientSecret") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12.5))

                    Button(action: { RedditOAuth.shared.signIn() }) {
                        Label("Mit Reddit anmelden", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)

                    Text("Erstelle eine App unter reddit.com/prefs/apps (Typ: web app, Redirect: http://127.0.0.1:7778/callback).")
                        .font(.system(size: 10)).foregroundColor(.secondary).italic()
                })
            }
        )
    }
}

// MARK: - WhatsApp Web Sheet (WKWebView mit web.whatsapp.com)

struct WhatsAppWebSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isConnected = false
    @State private var isLoading = true
    @State private var pageTitle = "WhatsApp Web"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "phone.bubble.fill").font(.title3).foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WhatsApp Web").font(.system(size: 14, weight: .semibold))
                    if isConnected {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(.koboldEmerald)
                            Text("Verknüpft").font(.system(size: 11)).foregroundColor(.koboldEmerald)
                        }
                    } else {
                        Text("Scanne den QR-Code mit deinem Handy").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button("Schließen") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.15))

            Divider().opacity(0.3)

            // WKWebView
            WhatsAppWebViewRepresentable(
                isConnected: $isConnected,
                isLoading: $isLoading,
                pageTitle: $pageTitle
            )
        }
        .frame(minWidth: 900, minHeight: 650)
        .frame(idealWidth: 1000, idealHeight: 750)
        .onChange(of: isConnected) {
            if isConnected {
                UserDefaults.standard.set(true, forKey: "kobold.whatsapp.webLinked")
            }
        }
    }
}

// MARK: - WhatsApp Web WKWebView (NSViewRepresentable)

struct WhatsAppWebViewRepresentable: NSViewRepresentable {
    @Binding var isConnected: Bool
    @Binding var isLoading: Bool
    @Binding var pageTitle: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // Persistent — Session bleibt erhalten
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        // Desktop Chrome User-Agent — WhatsApp Web blockiert mobile UAs
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        wv.allowsBackForwardNavigationGestures = true

        let url = URL(string: "https://web.whatsapp.com")!
        wv.load(URLRequest(url: url))

        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isConnected: $isConnected, isLoading: $isLoading, pageTitle: $pageTitle)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var isConnected: Binding<Bool>
        var isLoading: Binding<Bool>
        var pageTitle: Binding<String>
        private var connectionCheckTask: Task<Void, Never>?

        init(isConnected: Binding<Bool>, isLoading: Binding<Bool>, pageTitle: Binding<String>) {
            self.isConnected = isConnected
            self.isLoading = isLoading
            self.pageTitle = pageTitle
            super.init()
        }

        deinit {
            connectionCheckTask?.cancel()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.isLoading.wrappedValue = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading.wrappedValue = false
                self.pageTitle.wrappedValue = webView.title ?? "WhatsApp Web"
            }
            startConnectionCheck(webView: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.isLoading.wrappedValue = false }
        }

        /// Pollt alle 3 Sekunden ob WhatsApp den QR-Code-Screen verlassen hat
        /// (= User hat erfolgreich gescannt und ist verknüpft)
        private func startConnectionCheck(webView: WKWebView) {
            connectionCheckTask?.cancel()
            connectionCheckTask = Task { @MainActor [weak self, weak webView] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                    guard !Task.isCancelled, let webView = webView else { return }

                    // WhatsApp Web zeigt #pane-side (Chat-Liste) wenn verknüpft
                    // und [data-testid="qrcode"] wenn QR-Code angezeigt wird
                    let js = """
                    (() => {
                        const chatList = document.querySelector('#pane-side') ||
                                         document.querySelector('[data-testid="chat-list"]') ||
                                         document.querySelector('[aria-label="Chatliste"]') ||
                                         document.querySelector('[aria-label="Chat list"]');
                        return chatList !== null;
                    })()
                    """
                    do {
                        let result = try await webView.evaluateJavaScript(js)
                        let connected = (result as? Bool) == true
                        if connected != self?.isConnected.wrappedValue {
                            self?.isConnected.wrappedValue = connected
                        }
                    } catch {
                        // JS evaluation kann fehlschlagen wenn Seite noch lädt — ignorieren
                    }
                }
            }
        }
    }
}
