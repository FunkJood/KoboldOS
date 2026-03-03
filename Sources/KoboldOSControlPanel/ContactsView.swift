import SwiftUI

// MARK: - Kontakte Tab (Desktop)

struct ContactsView: View {
    @ObservedObject var viewModel: RuntimeViewModel
    @EnvironmentObject var l10n: LocalizationManager
    private var lang: AppLanguage { l10n.language }

    enum SubTab: String, CaseIterable { case kontakte, firmen, deals, aktivitaeten }

    @State private var subTab: SubTab = .kontakte
    @State private var contacts: [[String: Any]] = []
    @State private var companies: [[String: Any]] = []
    @State private var deals: [[String: Any]] = []
    @State private var activities: [[String: Any]] = []
    @State private var pipelineStages: [[String: Any]] = []
    @State private var isLoading = false
    @State private var errorMsg = ""
    @State private var searchText = ""
    @State private var statusFilter: String = "all"
    @State private var selectedContactId: String? = nil
    @State private var selectedContact: [String: Any]? = nil
    @State private var activeSheet: SheetType? = nil

    // Contact form
    @State private var formFirstName = ""
    @State private var formLastName = ""
    @State private var formEmail = ""
    @State private var formPhone = ""
    @State private var formCompany = ""
    @State private var formJobTitle = ""
    @State private var formStatus = "active"
    @State private var formTags = ""
    @State private var formNotes = ""

    // Company form
    @State private var compFormName = ""
    @State private var compFormIndustry = ""
    @State private var compFormWebsite = ""
    @State private var compFormSize = ""
    @State private var compFormNotes = ""

    // Deal form
    @State private var dealFormTitle = ""
    @State private var dealFormContactId = ""
    @State private var dealFormCompanyId = ""
    @State private var dealFormValue = ""
    @State private var dealFormStage = "lead"
    @State private var dealFormProbability = ""
    @State private var dealFormNotes = ""

    // Activity form
    @State private var actFormType = "note"
    @State private var actFormContactId = ""
    @State private var actFormTitle = ""
    @State private var actFormDescription = ""

    // Import status
    @State private var importStatus: String = ""
    @State private var isImporting = false

    enum SheetType: Identifiable {
        case addContact, editContact, addCompany, addDeal, addActivity
        var id: String { String(describing: self) }
    }

    private var statusFilters: [(String, String)] {
        [("all", lang.allFilter), ("active", lang.activeStatus), ("lead", lang.leadStatus), ("customer", lang.customerStatus), ("inactive", lang.inactiveStatus)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                subTabBar
                if !errorMsg.isEmpty { errorBanner }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                else {
                    switch subTab {
                    case .kontakte:  contactsContent
                    case .firmen:    companiesContent
                    case .deals:     dealsContent
                    case .aktivitaeten: activitiesContent
                    }
                }
            }
            .padding(24)
        }
        .background(
            ZStack {
                Color.koboldBackground
                LinearGradient(colors: [Color.koboldGold.opacity(0.03), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        )
        .task { await loadAll() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addContact:  addContactSheet
            case .editContact: editContactSheet
            case .addCompany:  addCompanySheet
            case .addDeal:     addDealSheet
            case .addActivity: addActivitySheet
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.contacts).font(.system(size: 24, weight: .bold))
                Text("\(contacts.count) \(lang.contacts) · \(companies.count) \(lang.companies) · \(deals.count) \(lang.deals)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text(importStatus).font(.caption).foregroundColor(.secondary)
                } else if !importStatus.isEmpty {
                    Text(importStatus).font(.caption).foregroundColor(importStatus.contains("Fehler") ? .red : .green)
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { importStatus = "" } }
                }
                GlassButton(title: lang.appleImport, icon: "person.crop.circle.badge.plus", isPrimary: false) {
                    Task { await importAppleContacts() }
                }.disabled(isImporting)
                GlassButton(title: lang.googleImport, icon: "globe", isPrimary: false) {
                    Task { await importGoogleContacts() }
                }.disabled(isImporting)
                GlassButton(title: lang.newCompany, icon: "building.2", isPrimary: false) {
                    resetCompanyForm(); activeSheet = .addCompany
                }
                GlassButton(title: lang.newContact, icon: "person.badge.plus", isPrimary: true) {
                    resetContactForm(); activeSheet = .addContact
                }
            }
        }
    }

    // MARK: - Sub-Tab Bar

    private var subTabBar: some View {
        HStack(spacing: 0) {
            ForEach(SubTab.allCases, id: \.self) { tab in
                let label: String = {
                    switch tab {
                    case .kontakte: return lang.contacts
                    case .firmen: return lang.companies
                    case .deals: return lang.deals
                    case .aktivitaeten: return lang.activities
                    }
                }()
                let icon: String = {
                    switch tab {
                    case .kontakte: return "person.2"
                    case .firmen: return "building.2"
                    case .deals: return "chart.bar"
                    case .aktivitaeten: return "clock.arrow.circlepath"
                    }
                }()
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { subTab = tab } }) {
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 11))
                        Text(label).font(.system(size: 12, weight: subTab == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(subTab == tab ? Color.koboldGold.opacity(0.15) : Color.clear)
                    .foregroundColor(subTab == tab ? .koboldGold : .secondary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Error Banner

    private var errorBanner: some View {
        GlassCard {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(errorMsg).font(.caption)
                Spacer()
                Button(lang.retry) { Task { await loadAll() } }
                    .font(.caption).foregroundColor(.koboldGold)
            }
        }
    }

    // MARK: - Kontakte Content

    private var filteredContacts: [[String: Any]] {
        var result = contacts
        if statusFilter != "all" {
            result = result.filter { ($0["status"] as? String ?? "active") == statusFilter }
        }
        if !searchText.isEmpty {
            result = result.filter { c in
                let first = c["firstName"] as? String ?? ""
                let last = c["lastName"] as? String ?? ""
                let email = (c["email"] as? [String])?.joined(separator: " ") ?? ""
                let company = c["company"] as? String ?? ""
                let full = "\(first) \(last) \(email) \(company)"
                return full.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    private var contactsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search + Filter
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(lang.searchDots, text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)

                ForEach(statusFilters, id: \.0) { (value, label) in
                    Button(action: { statusFilter = value }) {
                        Text(label)
                            .font(.system(size: 11, weight: statusFilter == value ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(statusFilter == value ? Color.koboldGold.opacity(0.15) : Color.white.opacity(0.04))
                            .foregroundColor(statusFilter == value ? .koboldGold : .secondary)
                            .cornerRadius(6)
                    }.buttonStyle(.plain)
                }
            }

            if filteredContacts.isEmpty {
                emptyState(icon: "person.2.slash", title: lang.noContacts, subtitle: lang.contactsEmptyDesc)
            } else {
                // Two-column layout: list + detail
                HStack(alignment: .top, spacing: 16) {
                    // Contact list
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(filteredContacts, id: \.contactId) { contact in
                                contactRow(contact)
                            }
                        }
                    }
                    .frame(width: 320)

                    // Detail panel
                    if let contact = selectedContact {
                        contactDetail(contact)
                    } else {
                        GlassCard {
                            VStack(spacing: 12) {
                                Image(systemName: "person.text.rectangle").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.5))
                                Text(lang.selectContact).font(.caption).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                }
            }
        }
    }

    private func contactRow(_ contact: [String: Any]) -> some View {
        let id = contact["id"] as? String ?? ""
        let first = contact["firstName"] as? String ?? ""
        let last = contact["lastName"] as? String ?? ""
        let status = contact["status"] as? String ?? "active"
        let company = contact["company"] as? String ?? ""
        let initials = "\(first.prefix(1))\(last.prefix(1))".uppercased()
        let isSelected = selectedContactId == id

        return Button(action: {
            selectedContactId = id
            selectedContact = contact
        }) {
            HStack(spacing: 10) {
                // Avatar
                ZStack {
                    Circle().fill(statusColor(status).opacity(0.2)).frame(width: 36, height: 36)
                    Text(initials).font(.system(size: 13, weight: .semibold)).foregroundColor(statusColor(status))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(first) \(last)").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !company.isEmpty {
                        Text(company).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                statusBadge(status)
            }
            .padding(8)
            .background(isSelected ? Color.koboldGold.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func contactDetail(_ contact: [String: Any]) -> some View {
        let first = contact["firstName"] as? String ?? ""
        let last = contact["lastName"] as? String ?? ""
        let emails = contact["email"] as? [String] ?? []
        let phones = contact["phone"] as? [String] ?? []
        let company = contact["company"] as? String ?? ""
        let jobTitle = contact["jobTitle"] as? String ?? ""
        let status = contact["status"] as? String ?? "active"
        let tags = contact["tags"] as? [String] ?? []
        let notes = contact["notes"] as? String ?? ""
        let id = contact["id"] as? String ?? ""
        let contactActivities = (contact["activities"] as? [[String: Any]]) ?? activities.filter { ($0["contactId"] as? String) == id }

        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    ZStack {
                        Circle().fill(statusColor(status).opacity(0.2)).frame(width: 48, height: 48)
                        Text("\(first.prefix(1))\(last.prefix(1))".uppercased())
                            .font(.system(size: 18, weight: .bold)).foregroundColor(statusColor(status))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(first) \(last)").font(.system(size: 18, weight: .bold))
                        if !jobTitle.isEmpty || !company.isEmpty {
                            Text([jobTitle, company].filter { !$0.isEmpty }.joined(separator: " \(lang.atCompany) "))
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    statusBadge(status)
                    Button(action: {
                        populateContactForm(contact)
                        activeSheet = .editContact
                    }) {
                        Image(systemName: "pencil").font(.system(size: 12)).padding(6)
                            .background(Color.white.opacity(0.06)).cornerRadius(6)
                    }.buttonStyle(.plain)
                    Button(action: { Task { await deleteContact(id: id) } }) {
                        Image(systemName: "trash").font(.system(size: 12)).padding(6)
                            .foregroundColor(.red.opacity(0.8))
                            .background(Color.red.opacity(0.06)).cornerRadius(6)
                    }.buttonStyle(.plain)
                }

                Divider().opacity(0.3)

                // Info grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    if !emails.isEmpty { infoField(icon: "envelope", label: lang.emailLabel, value: emails.joined(separator: ", ")) }
                    if !phones.isEmpty { infoField(icon: "phone", label: lang.phoneLabel, value: phones.joined(separator: ", ")) }
                    if !company.isEmpty { infoField(icon: "building.2", label: lang.companyLabel, value: company) }
                    if !jobTitle.isEmpty { infoField(icon: "briefcase", label: lang.positionLabel, value: jobTitle) }
                }

                // Tags
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "tag").font(.system(size: 10)).foregroundColor(.secondary)
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.koboldGold.opacity(0.1)).cornerRadius(4)
                                .foregroundColor(.koboldGold)
                        }
                    }
                }

                // Notes
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lang.notesLabel).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        Text(notes).font(.system(size: 12)).foregroundColor(.primary.opacity(0.8))
                    }
                }

                // Activities timeline
                if !contactActivities.isEmpty {
                    Divider().opacity(0.3)
                    Text(lang.activities).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    ForEach(contactActivities.prefix(5), id: \.activityId) { act in
                        HStack(spacing: 8) {
                            Image(systemName: activityIcon(act["type"] as? String ?? "note"))
                                .font(.system(size: 11)).foregroundColor(.koboldEmerald).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(act["title"] as? String ?? act["description"] as? String ?? "").font(.system(size: 12)).lineLimit(1)
                                Text(act["timestamp"] as? String ?? "").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Firmen Content

    private var companiesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if companies.isEmpty {
                emptyState(icon: "building.2.crop.circle", title: lang.noCompanies, subtitle: lang.companiesEmptyDesc)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(companies, id: \.companyId) { company in
                        companyCard(company)
                    }
                }
            }
        }
    }

    private func companyCard(_ company: [String: Any]) -> some View {
        let name = company["name"] as? String ?? ""
        let industry = company["industry"] as? String ?? ""
        let website = company["website"] as? String ?? ""
        let id = company["id"] as? String ?? ""
        let contactCount = contacts.filter { ($0["companyId"] as? String) == id }.count

        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "building.2.fill").foregroundColor(.koboldGold)
                    Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button(action: { Task { await deleteCompany(id: id) } }) {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red.opacity(0.6))
                    }.buttonStyle(.plain)
                }
                if !industry.isEmpty {
                    Text(industry).font(.system(size: 11)).foregroundColor(.secondary)
                }
                HStack {
                    if !website.isEmpty {
                        Label(website, systemImage: "globe").font(.system(size: 10)).foregroundColor(.blue.opacity(0.8)).lineLimit(1)
                    }
                    Spacer()
                    Text("\(contactCount) \(lang.contacts)").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Deals Kanban

    private var dealsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lang.pipelineLabel).font(.system(size: 16, weight: .semibold))
                Spacer()
                GlassButton(title: lang.newDeal, icon: "plus.circle", isPrimary: false) {
                    resetDealForm(); activeSheet = .addDeal
                }
            }
            if pipelineStages.isEmpty || deals.isEmpty {
                emptyState(icon: "chart.bar.doc.horizontal", title: lang.noDeals, subtitle: lang.dealsEmptyDesc)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(pipelineStages, id: \.stageId) { stage in
                            kanbanColumn(stage)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func kanbanColumn(_ stage: [String: Any]) -> some View {
        let stageId = stage["id"] as? String ?? ""
        let stageName = stage["name"] as? String ?? ""
        let colorHex = stage["color"] as? String ?? "#94a3b8"
        let stageDeals = deals.filter { ($0["stage"] as? String) == stageId }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Color(hex: colorHex)).frame(width: 8, height: 8)
                Text(stageName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(stageDeals.count)").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(hex: colorHex).opacity(0.08))
            .cornerRadius(8)

            if stageDeals.isEmpty {
                Text(lang.noDeals).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ForEach(stageDeals, id: \.dealId) { deal in
                    dealCard(deal)
                }
            }
        }
        .frame(width: 200)
    }

    private func dealCard(_ deal: [String: Any]) -> some View {
        let title = deal["title"] as? String ?? ""
        let value = deal["value"] as? Double ?? 0
        let contactId = deal["contactId"] as? String ?? ""
        let contactName = contacts.first(where: { ($0["id"] as? String) == contactId })
            .map { "\($0["firstName"] as? String ?? "") \($0["lastName"] as? String ?? "")" } ?? ""

        return GlassCard(padding: 8, cornerRadius: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if value > 0 {
                    Text(String(format: "%.0f €", value)).font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.koboldEmerald)
                }
                if !contactName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(contactName).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }

    // MARK: - Aktivitaeten Content

    private var activitiesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lang.activities).font(.system(size: 16, weight: .semibold))
                Spacer()
                GlassButton(title: lang.newActivity, icon: "plus.circle", isPrimary: false) {
                    resetActivityForm(); activeSheet = .addActivity
                }
            }
            if activities.isEmpty {
                emptyState(icon: "clock.arrow.circlepath", title: lang.noActivities, subtitle: lang.activitiesEmptyDesc)
            } else {
                ForEach(activities.prefix(50), id: \.activityId) { act in
                    activityRow(act)
                }
            }
        }
    }

    private func activityRow(_ act: [String: Any]) -> some View {
        let type = act["type"] as? String ?? "note"
        let title = act["title"] as? String ?? act["description"] as? String ?? ""
        let timestamp = act["timestamp"] as? String ?? ""
        let contactId = act["contactId"] as? String ?? ""
        let contactName = contacts.first(where: { ($0["id"] as? String) == contactId })
            .map { "\($0["firstName"] as? String ?? "") \($0["lastName"] as? String ?? "")" } ?? ""

        return GlassCard(padding: 10, cornerRadius: 8) {
            HStack(spacing: 10) {
                Image(systemName: activityIcon(type))
                    .font(.system(size: 14)).foregroundColor(.koboldEmerald).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    HStack(spacing: 8) {
                        if !contactName.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(contactName).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Text(timestamp.prefix(10)).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Sheets

    private var addContactSheet: some View {
        contactFormSheet(title: lang.newContact) {
            Task { await createContact(); activeSheet = nil }
        }
    }

    private var editContactSheet: some View {
        contactFormSheet(title: lang.editContact) {
            if let id = selectedContactId {
                Task { await updateContact(id: id); activeSheet = nil }
            }
        }
    }

    private func contactFormSheet(title: String, onSave: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.firstName).font(.caption).foregroundColor(.secondary)
                    TextField(lang.firstName, text: $formFirstName).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.lastName).font(.caption).foregroundColor(.secondary)
                    TextField(lang.lastName, text: $formLastName).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.emailLabel).font(.caption).foregroundColor(.secondary)
                    TextField("email@example.com", text: $formEmail).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.phoneLabel).font(.caption).foregroundColor(.secondary)
                    TextField("+49...", text: $formPhone).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.companyLabel).font(.caption).foregroundColor(.secondary)
                    TextField(lang.companyLabel, text: $formCompany).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.positionLabel).font(.caption).foregroundColor(.secondary)
                    TextField("CEO, CTO...", text: $formJobTitle).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.statusLabel).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $formStatus) {
                        Text(lang.activeStatus).tag("active")
                        Text(lang.leadStatus).tag("lead")
                        Text(lang.customerStatus).tag("customer")
                        Text(lang.inactiveStatus).tag("inactive")
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.tagsCommaSep).font(.caption).foregroundColor(.secondary)
                    TextField("VIP, Partner", text: $formTags).textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.notesLabel).font(.caption).foregroundColor(.secondary)
                TextEditor(text: $formNotes).frame(height: 60).font(.system(size: 12))
                    .padding(4).background(Color.white.opacity(0.05)).cornerRadius(6)
            }
            HStack {
                Button(lang.cancel) { activeSheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(lang.save, action: onSave).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500)
    }

    private var addCompanySheet: some View {
        VStack(spacing: 16) {
            Text(lang.newCompany).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.nameLabel).font(.caption).foregroundColor(.secondary)
                TextField(lang.companyLabel, text: $compFormName).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.industryLabel).font(.caption).foregroundColor(.secondary)
                    TextField("Technology, Finance...", text: $compFormIndustry).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.websiteLabel).font(.caption).foregroundColor(.secondary)
                    TextField("https://...", text: $compFormWebsite).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.sizeLabel).font(.caption).foregroundColor(.secondary)
                    TextField("50-100", text: $compFormSize).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.notesLabel).font(.caption).foregroundColor(.secondary)
                    TextField("...", text: $compFormNotes).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button(lang.cancel) { activeSheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(lang.save) { Task { await createCompany(); activeSheet = nil } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 450)
    }

    private var addDealSheet: some View {
        VStack(spacing: 16) {
            Text(lang.newDeal).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.titleLabel).font(.caption).foregroundColor(.secondary)
                TextField(lang.titleLabel, text: $dealFormTitle).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.contacts).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $dealFormContactId) {
                        Text(lang.noContact).tag("")
                        ForEach(contacts, id: \.contactId) { c in
                            Text("\(c["firstName"] as? String ?? "") \(c["lastName"] as? String ?? "")")
                                .tag(c["id"] as? String ?? "")
                        }
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.stageLabel).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $dealFormStage) {
                        ForEach(pipelineStages, id: \.stageId) { s in
                            Text(s["name"] as? String ?? "").tag(s["id"] as? String ?? "")
                        }
                    }.labelsHidden()
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.dealValue).font(.caption).foregroundColor(.secondary)
                    TextField("0", text: $dealFormValue).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.dealProb).font(.caption).foregroundColor(.secondary)
                    TextField("50", text: $dealFormProbability).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button(lang.cancel) { activeSheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(lang.save) { Task { await createDeal(); activeSheet = nil } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 450)
    }

    private var addActivitySheet: some View {
        VStack(spacing: 16) {
            Text(lang.newActivity).font(.headline)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.typeLabel).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $actFormType) {
                        Text(lang.noteLabel).tag("note")
                        Text(lang.callLabel).tag("call")
                        Text(lang.emailLabel).tag("email")
                        Text(lang.meetingLabel).tag("meeting")
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.contacts).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $actFormContactId) {
                        Text(lang.noContact).tag("")
                        ForEach(contacts, id: \.contactId) { c in
                            Text("\(c["firstName"] as? String ?? "") \(c["lastName"] as? String ?? "")")
                                .tag(c["id"] as? String ?? "")
                        }
                    }.labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.titleLabel).font(.caption).foregroundColor(.secondary)
                TextField(lang.titleLabel, text: $actFormTitle).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.description_).font(.caption).foregroundColor(.secondary)
                TextEditor(text: $actFormDescription).frame(height: 60).font(.system(size: 12))
                    .padding(4).background(Color.white.opacity(0.05)).cornerRadius(6)
            }
            HStack {
                Button(lang.cancel) { activeSheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(lang.save) { Task { await createActivity(); activeSheet = nil } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 450)
    }

    // MARK: - Helpers

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 40)).foregroundColor(.secondary.opacity(0.4))
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func infoField(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                Text(value).font(.system(size: 12)).lineLimit(1)
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let label: String = {
            switch status {
            case "active": return lang.activeStatus
            case "lead": return lang.leadStatus
            case "customer": return lang.customerStatus
            case "inactive": return lang.inactiveStatus
            default: return status
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(statusColor(status).opacity(0.15))
            .foregroundColor(statusColor(status))
            .cornerRadius(4)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "active": return .koboldEmerald
        case "lead": return .blue
        case "customer": return .koboldGold
        case "inactive": return .secondary
        default: return .secondary
        }
    }

    private func activityIcon(_ type: String) -> String {
        switch type {
        case "call": return "phone.fill"
        case "email": return "envelope.fill"
        case "meeting": return "person.2.fill"
        case "note": return "note.text"
        default: return "circle.fill"
        }
    }

    // MARK: - Form Helpers

    private func resetContactForm() {
        formFirstName = ""; formLastName = ""; formEmail = ""; formPhone = ""
        formCompany = ""; formJobTitle = ""; formStatus = "active"; formTags = ""; formNotes = ""
    }

    private func populateContactForm(_ c: [String: Any]) {
        formFirstName = c["firstName"] as? String ?? ""
        formLastName = c["lastName"] as? String ?? ""
        formEmail = (c["email"] as? [String])?.joined(separator: ", ") ?? ""
        formPhone = (c["phone"] as? [String])?.joined(separator: ", ") ?? ""
        formCompany = c["company"] as? String ?? ""
        formJobTitle = c["jobTitle"] as? String ?? ""
        formStatus = c["status"] as? String ?? "active"
        formTags = (c["tags"] as? [String])?.joined(separator: ", ") ?? ""
        formNotes = c["notes"] as? String ?? ""
    }

    private func resetCompanyForm() { compFormName = ""; compFormIndustry = ""; compFormWebsite = ""; compFormSize = ""; compFormNotes = "" }
    private func resetDealForm() { dealFormTitle = ""; dealFormContactId = ""; dealFormCompanyId = ""; dealFormValue = ""; dealFormStage = "lead"; dealFormProbability = ""; dealFormNotes = "" }
    private func resetActivityForm() { actFormType = "note"; actFormContactId = ""; actFormTitle = ""; actFormDescription = "" }

    // MARK: - API

    private func loadAll() async {
        isLoading = true; errorMsg = ""
        defer { isLoading = false }
        guard viewModel.isConnected else { errorMsg = lang.daemonDisconnected; return }

        contacts = await loadCollection("contacts")
        companies = await loadCollection("companies")
        deals = await loadCollection("deals")
        activities = await loadActivitiesData()
        pipelineStages = await loadPipelineStagesData()
    }

    private func loadCollection(_ name: String) async -> [[String: Any]] {
        guard let url = URL(string: viewModel.baseURL + "/\(name)") else { return [] }
        guard let (data, resp) = try? await viewModel.authorizedData(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json[name] as? [[String: Any]] else { return [] }
        return list
    }

    private func postAction(collection: String, body: [String: Any]) async {
        guard let url = URL(string: viewModel.baseURL + "/\(collection)") else { return }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    private func loadActivitiesData() async -> [[String: Any]] {
        guard let url = URL(string: viewModel.baseURL + "/activities") else { return [] }
        guard let (data, resp) = try? await viewModel.authorizedData(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["activities"] as? [[String: Any]] else { return [] }
        return list
    }

    private func loadPipelineStagesData() async -> [[String: Any]] {
        guard let url = URL(string: viewModel.baseURL + "/pipeline-stages") else { return [] }
        guard let (data, resp) = try? await viewModel.authorizedData(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["stages"] as? [[String: Any]] else { return [] }
        return list
    }

    private func createContact() async {
        let emails = formEmail.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let phones = formPhone.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = formTags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await postAction(collection: "contacts", body: [
            "action": "create", "data": [
                "firstName": formFirstName, "lastName": formLastName,
                "email": emails, "phone": phones,
                "company": formCompany, "jobTitle": formJobTitle,
                "status": formStatus, "tags": tags, "notes": formNotes
            ] as [String: Any]
        ])
        await loadAll()
    }

    private func updateContact(id: String) async {
        let emails = formEmail.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let phones = formPhone.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = formTags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await postAction(collection: "contacts", body: [
            "action": "update", "id": id, "data": [
                "firstName": formFirstName, "lastName": formLastName,
                "email": emails, "phone": phones,
                "company": formCompany, "jobTitle": formJobTitle,
                "status": formStatus, "tags": tags, "notes": formNotes
            ] as [String: Any]
        ])
        selectedContact = nil; selectedContactId = nil
        await loadAll()
    }

    private func deleteContact(id: String) async {
        await postAction(collection: "contacts", body: ["action": "delete", "id": id])
        if selectedContactId == id { selectedContact = nil; selectedContactId = nil }
        await loadAll()
    }

    private func createCompany() async {
        await postAction(collection: "companies", body: [
            "action": "create", "data": [
                "name": compFormName, "industry": compFormIndustry,
                "website": compFormWebsite, "size": compFormSize, "notes": compFormNotes
            ] as [String: Any]
        ])
        await loadAll()
    }

    private func deleteCompany(id: String) async {
        await postAction(collection: "companies", body: ["action": "delete", "id": id])
        await loadAll()
    }

    private func createDeal() async {
        await postAction(collection: "deals", body: [
            "action": "create", "data": [
                "title": dealFormTitle, "contactId": dealFormContactId,
                "companyId": dealFormCompanyId, "value": Double(dealFormValue) ?? 0,
                "stage": dealFormStage, "probability": Int(dealFormProbability) ?? 50,
                "notes": dealFormNotes
            ] as [String: Any]
        ])
        await loadAll()
    }

    private func createActivity() async {
        await postAction(collection: "activities", body: [
            "action": "create", "data": [
                "type": actFormType, "contactId": actFormContactId,
                "title": actFormTitle, "description": actFormDescription,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ] as [String: Any]
        ])
        await loadAll()
    }

    private func importAppleContacts() async {
        guard let url = URL(string: viewModel.baseURL + "/contacts/import-apple") else { return }
        isImporting = true; importStatus = "Apple Kontakte werden importiert..."
        defer { isImporting = false }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    importStatus = "Fehler: \(error)"
                } else if let count = json["imported"] as? Int, let skipped = json["skipped"] as? Int {
                    importStatus = "\(count) importiert, \(skipped) übersprungen"
                } else {
                    importStatus = "Import abgeschlossen"
                }
            }
        } catch {
            importStatus = "Fehler: \(error.localizedDescription)"
        }
        await loadAll()
    }

    private func importGoogleContacts() async {
        guard let url = URL(string: viewModel.baseURL + "/contacts/import-google") else { return }
        isImporting = true; importStatus = "Google Kontakte werden importiert..."
        defer { isImporting = false }
        var req = viewModel.authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    importStatus = "Fehler: \(error)"
                } else if let count = json["imported"] as? Int, let skipped = json["skipped"] as? Int {
                    importStatus = "\(count) importiert, \(skipped) übersprungen"
                } else {
                    importStatus = "Import abgeschlossen"
                }
            }
        } catch {
            importStatus = "Fehler: \(error.localizedDescription)"
        }
        await loadAll()
    }
}

// MARK: - Dictionary ID Extensions

private extension Dictionary where Key == String, Value == Any {
    var contactId: String { self["id"] as? String ?? UUID().uuidString }
    var companyId: String { self["id"] as? String ?? UUID().uuidString }
    var dealId: String { self["id"] as? String ?? UUID().uuidString }
    var activityId: String { self["id"] as? String ?? UUID().uuidString }
    var stageId: String { self["id"] as? String ?? UUID().uuidString }
}

// Color(hex:) extension already defined in ColorExtensions.swift
