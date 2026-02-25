import SwiftUI
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
        connectionCard(
            logo: AnyView(Image(systemName: "phone.bubble.fill").font(.title2).foregroundColor(.green)),
            name: "WhatsApp",
            subtitle: "Business API (Meta)",
            isConnected: WhatsAppOAuth.shared.isConnected,
            connectedDetail: {
                AnyView(VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.fill").foregroundColor(.secondary)
                        Text(WhatsAppOAuth.shared.userName).font(.system(size: 13))
                    }
                    HStack {
                        Text("Phone Number ID:").font(.system(size: 11)).foregroundColor(.secondary)
                        TextField("ID", text: Binding(
                            get: { UserDefaults.standard.string(forKey: "kobold.whatsapp.phoneNumberId") ?? "" },
                            set: { UserDefaults.standard.set($0, forKey: "kobold.whatsapp.phoneNumberId") }
                        )).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 200)
                    }
                    Button("Abmelden") { Task { await WhatsAppOAuth.shared.signOut() } }
                        .font(.system(size: 12)).foregroundColor(.red)
                })
            },
            signInButton: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("Meta App-Konfiguration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("App ID (Client ID)").font(.system(size: 11)).foregroundColor(.secondary)
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
                            TextField("WhatsApp Phone Number ID", text: Binding(
                                get: { UserDefaults.standard.string(forKey: "kobold.whatsapp.phoneNumberId") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "kobold.whatsapp.phoneNumberId") }
                            )).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                    }.font(.system(size: 12.5))

                    Button(action: { WhatsAppOAuth.shared.signIn() }) {
                        Label("Mit WhatsApp verbinden", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                })
            }
        )
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
            logo: AnyView(Image(systemName: "message.fill").font(.title2).foregroundColor(.red)),
            name: "SMS (Twilio)",
            subtitle: "SMS senden via Twilio",
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
                    Button("Zugangsdaten entfernen") {
                        for k in ["kobold.twilio.accountSid", "kobold.twilio.authToken", "kobold.twilio.fromNumber"] {
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
}
