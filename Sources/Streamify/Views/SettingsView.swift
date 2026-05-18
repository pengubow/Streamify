import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var localServer = LocalServer.shared
    @State private var showImportSources: Bool = false
    @State private var showDeveloper: Bool = false
    @State private var portText: String = ""
    @State private var isApplyingPort: Bool = false
    @FocusState private var focusedField: SettingsFocusField?
    @AppStorage("developerMode") private var developerMode: Bool = false
    @AppStorage("preferredSubtitleLanguages") private var preferredSubtitleLanguages: String = "English"
    @AppStorage("preferredAudioLanguages") private var preferredAudioLanguages: String = "English"
    @AppStorage("preferredGenres") private var preferredGenresRaw: String = ""
    @AppStorage("tmdbApiKey") private var tmdbApiKey: String = ""
    @AppStorage("vidLinkEnabled") private var vidLinkEnabled: Bool = true
    @AppStorage("movies111Enabled") private var movies111Enabled: Bool = true
    @AppStorage("torrentioEnabled") private var torrentioEnabled: Bool = false
    @AppStorage("torrentioDebridProvider") private var torrentioDebridProvider: String = TorrentioService.DebridProvider.realdebrid.rawValue
    @AppStorage("torrentioRealDebridApiKey") private var torrentioRealDebridApiKey: String = ""
    @AppStorage("torrentioPremiumizeApiKey") private var torrentioPremiumizeApiKey: String = ""
    @AppStorage("torrentioAllDebridApiKey") private var torrentioAllDebridApiKey: String = ""
    @AppStorage("torrentioDebridLinkApiKey") private var torrentioDebridLinkApiKey: String = ""
    @AppStorage("torrentioEasyDebridApiKey") private var torrentioEasyDebridApiKey: String = ""
    @AppStorage("torrentioOffcloudApiKey") private var torrentioOffcloudApiKey: String = ""
    @AppStorage("torrentioTorBoxApiKey") private var torrentioTorBoxApiKey: String = ""
    @AppStorage("torrentioPutioClientId") private var torrentioPutioClientId: String = ""
    @AppStorage("torrentioPutioToken") private var torrentioPutioToken: String = ""
    @State private var serverHealthy: Bool? = nil
    @State private var showLanguagePicker: Bool = false
    @State private var showGenrePicker: Bool = false
    @State private var showDebridProviderPicker: Bool = false

    private enum SettingsFocusField: Hashable {
        case tmdbApiKey
        case serverPort
    }

    private var selectedLanguages: Set<String> {
        StreamifyPreferences.languages(from: preferredSubtitleLanguages)
    }

    private var selectedGenres: Set<Genre> {
        StreamifyPreferences.genres(from: preferredGenresRaw)
    }

    private var selectedTorrentioDebridProvider: TorrentioService.DebridProvider {
        TorrentioService.DebridProvider(rawValue: torrentioDebridProvider) ?? .realdebrid
    }

    var body: some View {
        StreamifyNavigationContainer {
            ZStack {
                StreamifyPageBackground()

                ScrollView {
                    VStack(spacing: 24) {
                        // App info header
                        VStack(spacing: 10) {
                            StreamifyIconWell(icon: "play.rectangle.fill", tint: .blue)
                                .scaleEffect(1.16)

                            Text("Streamify")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)

                            Text("Your Personal Streaming App")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .padding(.top, 32)
                        .padding(.bottom, 16)

                        // Import options
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "Content")

                            Button {
                                if tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    focusedField = .tmdbApiKey
                                } else {
                                    showImportSources = true
                                }
                            } label: {
                                HStack {
                                    Image(systemName: tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key.fill" : "link")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Add TMDB API Key" : "Manage Sources")
                                            .font(.headline)
                                            .foregroundStyle(.white)

                                        Text(tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Required for search and TMDB-based streaming sources" : "Import or delete sources for streaming")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }

                                    Spacer()
                                }
                                .padding(16)
                                .streamifyPanel(cornerRadius: 10)
                            }
                        }
                        .padding(.horizontal, 16)

                        // TMDB section
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "TMDB")

                            VStack(spacing: 12) {
                                HStack {
                                    Image(systemName: "film")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("TMDB API Key")
                                            .font(.headline)
                                            .foregroundStyle(.white)

                                        Text("For popular movies, TV shows, and search")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }

                                    Spacer()
                                }

                                SecureField("Enter TMDB API key (v3 auth)", text: $tmdbApiKey)
                                    .focused($focusedField, equals: .tmdbApiKey)
                                    .streamifyTextInput(isFocused: focusedField == .tmdbApiKey)

                                if !tmdbApiKey.isEmpty {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                        Text("API key configured")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)

                        // Streaming sources section
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "Streaming Sources")

                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    Image(systemName: "link.badge.plus")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                        .frame(width: 36, height: 36)
                                        .background(Color.blue.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("VidLink")
                                            .font(.headline)
                                            .foregroundStyle(.white)

                                        Text("Fast online HLS source via TMDB ID")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }

                                    Spacer()

                                    Toggle("", isOn: $vidLinkEnabled)
                                        .labelsHidden()
                                        .tint(.blue)
                                }

                                Divider().background(Color.gray.opacity(0.3))

                                HStack(spacing: 12) {
                                    Image(systemName: "film.stack")
                                        .font(.title2)
                                        .foregroundStyle(.purple)
                                        .frame(width: 36, height: 36)
                                        .background(Color.purple.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("111Movies")
                                            .font(.headline)
                                            .foregroundStyle(.white)

                                        Text("Alternative online HLS source via TMDB ID")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }

                                    Spacer()

                                    Toggle("", isOn: $movies111Enabled)
                                        .labelsHidden()
                                        .tint(.purple)
                                }

                                Divider().background(Color.gray.opacity(0.3))

                                HStack(spacing: 12) {
                                    Image(systemName: "bolt.horizontal.circle")
                                        .font(.title2)
                                        .foregroundStyle(.purple)
                                        .frame(width: 36, height: 36)
                                        .background(Color.purple.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Torrentio")
                                            .font(.headline)
                                            .foregroundStyle(.white)

                                        Text("Fetch direct Stremio streams via IMDb ID")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }

                                    Spacer()

                                    Toggle("", isOn: $torrentioEnabled)
                                        .labelsHidden()
                                        .tint(.purple)
                                }

                                if torrentioEnabled {
                                    Divider().background(Color.gray.opacity(0.3))

                                    HStack {
                                        Text("Debrid")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Button {
                                            showDebridProviderPicker = true
                                        } label: {
                                            HStack(spacing: 6) {
                                                Text(selectedTorrentioDebridProvider.displayName)
                                                    .font(.subheadline)
                                                Image(systemName: "chevron.up.chevron.down")
                                                    .font(.caption2.weight(.semibold))
                                            }
                                            .foregroundStyle(.purple)
                                        }
                                    }

                                    if selectedTorrentioDebridProvider == .putio {
                                        torrentioSecureField("Put.io Client ID", text: $torrentioPutioClientId)
                                        torrentioSecureField("Put.io Token", text: $torrentioPutioToken)
                                    } else if selectedTorrentioDebridProvider != .none {
                                        torrentioSecureField(
                                            "\(selectedTorrentioDebridProvider.displayName) API key",
                                            text: torrentioDebridKeyBinding(for: selectedTorrentioDebridProvider)
                                        )
                                    }

                                    if selectedTorrentioDebridProvider != .none {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(isSelectedDebridConfigured ? Color.green : Color.orange)
                                                .frame(width: 8, height: 8)
                                            Text(isSelectedDebridConfigured ? "\(selectedTorrentioDebridProvider.displayName) configured" : "Debrid key missing")
                                                .font(.caption)
                                                .foregroundStyle(isSelectedDebridConfigured ? .green : .orange)
                                            Spacer()
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // Server section
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "Local Server")

                            VStack(spacing: 12) {
                                // Server status
                                HStack {
                                    Text("Status")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(localServer.isRunning ? Color.green : Color.red)
                                            .frame(width: 8, height: 8)
                                        Text(localServer.isRunning ? "Running" : "Stopped")
                                            .font(.subheadline)
                                            .foregroundStyle(localServer.isRunning ? .green : .red)
                                    }
                                }

                                Divider().background(Color.gray.opacity(0.3))

                                // Health check
                                HStack {
                                    Text("Health")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    HStack(spacing: 6) {
                                        if let isHealthy = serverHealthy {
                                            Circle()
                                                .fill(isHealthy ? Color.green : Color.red)
                                                .frame(width: 8, height: 8)
                                            Text(isHealthy ? "Connected" : "Cannot connect")
                                                .font(.subheadline)
                                                .foregroundStyle(isHealthy ? .green : .red)
                                        } else {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                                .frame(width: 8, height: 8)
                                            Text("Checking...")
                                                .font(.subheadline)
                                                .foregroundStyle(.gray)
                                        }
                                    }
                                }

                                Divider().background(Color.gray.opacity(0.3))

                                // Port setting
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Port")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        TextField("8080", text: $portText)
                                            .font(.subheadline.monospacedDigit())
                                            .multilineTextAlignment(.trailing)
                                            .frame(width: 86)
                                            .keyboardType(.numberPad)
                                            .focused($focusedField, equals: .serverPort)
                                            .streamifyTextInput(minHeight: 38, isFocused: focusedField == .serverPort)
                                            .onAppear {
                                                syncPortText()
                                            }
                                            .onSubmit {
                                                applyPortChange()
                                            }
                                            .onChange(of: portText) { newValue in
                                                filterPortInput(newValue)
                                            }
                                    }

                                    if let message = portValidationMessage {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.85))
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    } else if hasUnsavedPortChange {
                                        Button {
                                            applyPortChange()
                                        } label: {
                                            HStack(spacing: 8) {
                                                if isApplyingPort {
                                                    ProgressView()
                                                        .tint(.white)
                                                } else {
                                                    Image(systemName: "checkmark.circle.fill")
                                                }

                                                Text(localServer.isRunning ? "Save & Restart Server" : "Save Port")
                                                    .font(.subheadline.weight(.semibold))
                                            }
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.blue)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.97))
                                        .disabled(isApplyingPort || !isPortDraftValid)
                                        .opacity(isPortDraftValid && !isApplyingPort ? 1 : 0.55)
                                    }
                                }

                                Divider().background(Color.gray.opacity(0.3))

                                // Server URL when running
                                if localServer.isRunning {
                                    HStack {
                                        Text("URL")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text(localServer.baseURL)
                                            .font(.subheadline.monospaced())
                                            .foregroundStyle(.blue)
                                    }
                                    Divider().background(Color.gray.opacity(0.3))
                                }

                                // Start/Stop button
                                Button {
                                    focusedField = nil
                                    if localServer.isRunning {
                                        localServer.stop()
                                    } else {
                                        guard savePortDraft(restartIfRunning: false) else { return }
                                        localServer.start()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: localServer.isRunning ? "stop.circle.fill" : "play.circle.fill")
                                            .font(.title3)
                                        Text(localServer.isRunning ? "Stop Server" : "Start Server")
                                            .font(.headline)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(localServer.isRunning ? Color.red : Color.green)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .disabled(isApplyingPort || (!localServer.isRunning && !isPortDraftValid))
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // Developer section
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "Developer")

                            VStack(spacing: 12) {
                                // Developer mode toggle
                                HStack {
                                    Text("Developer Mode")
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Toggle("", isOn: $developerMode)
                                        .labelsHidden()
                                        .tint(.blue)
                                }

                                if developerMode {
                                    Divider().background(Color.gray.opacity(0.3))

                                    // Developer tools button
                                    Button {
                                        showDeveloper = true
                                    } label: {
                                        HStack {
                                            Image(systemName: "hammer.fill")
                                                .font(.title3)
                                            Text("Developer Tools")
                                                .font(.headline)
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // Playback section
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "Playback")

                            VStack(spacing: 12) {
                                Button {
                                    showLanguagePicker = true
                                } label: {
                                    HStack {
                                        Text("Preferred Languages")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Text("\(selectedLanguages.count) selected")
                                                .font(.subheadline)
                                                .foregroundStyle(.gray)
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                    }
                                }

                                // Selected languages display
                                if !selectedLanguages.isEmpty {
                                    StreamifyFlowLayout(spacing: 6) {
                                        ForEach(Array(selectedLanguages).sorted(), id: \.self) { lang in
                                            Text(lang)
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.3))
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                }

                                Text("Subtitles and audio in these languages will be downloaded automatically when available")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Divider().background(Color.gray.opacity(0.3))

                                Button {
                                    showGenrePicker = true
                                } label: {
                                    HStack {
                                        Text("Preferred Genres")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Text(selectedGenres.isEmpty ? "None" : "\(selectedGenres.count) selected")
                                                .font(.subheadline)
                                                .foregroundStyle(.gray)
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                    }
                                }
                                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))

                                if !selectedGenres.isEmpty {
                                    StreamifyFlowLayout(spacing: 6) {
                                        ForEach(Array(selectedGenres).sorted { $0.rawValue < $1.rawValue }) { genre in
                                            Text(genre.rawValue)
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.white.opacity(0.12))
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                }

                                Text("Home and featured picks will bias TMDB rows toward these genres")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // About section
                        VStack(spacing: 16) {
                            StreamifySectionHeader(title: "About")

                            VStack(spacing: 12) {
                                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                                aboutRow(title: "Version", value: version)
                                Divider().background(Color.gray.opacity(0.3))
                                aboutRow(title: "Build", value: build)
                            }
                            .padding(16)
                            .streamifyPanel(cornerRadius: 10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        Spacer(minLength: 86)
                    }
                }
                .streamifyScrollDismissesKeyboardInteractively()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .streamifyNavigationChrome()
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField != nil {
                        Spacer()
                        Button("Done") {
                            if focusedField == .serverPort {
                                applyPortChange()
                            } else {
                                focusedField = nil
                            }
                        }
                        .disabled(isApplyingPort)
                    }
                }
            }
            .sheet(isPresented: $showImportSources) {
                ImportSourcesView(viewModel: viewModel)
            }
            .sheet(isPresented: $showDeveloper) {
                DeveloperView(viewModel: viewModel)
            }
        }
        .preferredColorScheme(.dark)
        .streamifyBottomPopup(isPresented: $showLanguagePicker) {
            LanguagePickerSheet(selectedLanguages: Binding(
                get: { selectedLanguages },
                set: { newLangs in
                    let joined = StreamifyPreferences.rawValue(forLanguages: newLangs)
                    preferredSubtitleLanguages = joined
                    preferredAudioLanguages = joined
                }
            ), onDone: {
                showLanguagePicker = false
            })
        }
        .streamifyBottomPopup(isPresented: $showGenrePicker) {
            GenrePickerSheet(selectedGenres: Binding(
                get: { selectedGenres },
                set: { preferredGenresRaw = StreamifyPreferences.rawValue(forGenres: $0) }
            ), onDone: {
                showGenrePicker = false
            })
        }
        .streamifyBottomPopup(isPresented: $showDebridProviderPicker) {
            DebridProviderPickerView(
                selectedProvider: $torrentioDebridProvider,
                onDone: {
                    showDebridProviderPicker = false
                }
            )
        }
        .onAppear {
            syncPortText()
            Task {
                serverHealthy = await localServer.checkServerHealth()
                if serverHealthy == false && !localServer.isManuallyStopped {
                    let restarted = await LocalServer.shared.ensureRunningAsync()
                    if restarted {
                        serverHealthy = await localServer.checkServerHealth()
                    }
                }
            }
        }
        .task {
            // Periodic server health check — runs while the view is visible.
            // CancellationError from Task.sleep is caught to exit the loop without
            // making the closure throwing (SwiftUI .task requires non-throwing).
            while true {
                var isHealthy = await localServer.checkServerHealth()
                // Only auto-restart if the server wasn't intentionally stopped by the user.
                if !isHealthy &&
                    !localServer.isManuallyStopped &&
                    !isApplyingPort &&
                    focusedField != .serverPort &&
                    !hasUnsavedPortChange {
                    let restarted = await LocalServer.shared.ensureRunningAsync()
                    if restarted {
                        isHealthy = await localServer.checkServerHealth()
                    }
                }
                serverHealthy = isHealthy
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return } // 3 s
            }
        }
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
    }

    private var isSelectedDebridConfigured: Bool {
        switch selectedTorrentioDebridProvider {
        case .none:
            return false
        case .putio:
            return !torrentioPutioClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !torrentioPutioToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !torrentioDebridKey(for: selectedTorrentioDebridProvider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private func torrentioDebridKey(for provider: TorrentioService.DebridProvider) -> String {
        switch provider {
        case .none, .putio:
            return ""
        case .realdebrid:
            return torrentioRealDebridApiKey
        case .premiumize:
            return torrentioPremiumizeApiKey
        case .alldebrid:
            return torrentioAllDebridApiKey
        case .debridlink:
            return torrentioDebridLinkApiKey
        case .easydebrid:
            return torrentioEasyDebridApiKey
        case .offcloud:
            return torrentioOffcloudApiKey
        case .torbox:
            return torrentioTorBoxApiKey
        }
    }

    private func torrentioDebridKeyBinding(for provider: TorrentioService.DebridProvider) -> Binding<String> {
        switch provider {
        case .none, .putio:
            return .constant("")
        case .realdebrid:
            return $torrentioRealDebridApiKey
        case .premiumize:
            return $torrentioPremiumizeApiKey
        case .alldebrid:
            return $torrentioAllDebridApiKey
        case .debridlink:
            return $torrentioDebridLinkApiKey
        case .easydebrid:
            return $torrentioEasyDebridApiKey
        case .offcloud:
            return $torrentioOffcloudApiKey
        case .torbox:
            return $torrentioTorBoxApiKey
        }
    }

    private func torrentioSecureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .streamifyTextInput()
    }

    private var trimmedPortText: String {
        portText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var portDraftValue: UInt16? {
        guard let value = Int(trimmedPortText), value > 0, value <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(value)
    }

    private var isPortDraftValid: Bool {
        portDraftValue != nil
    }

    private var hasUnsavedPortChange: Bool {
        trimmedPortText != String(localServer.preferredPort)
    }

    private var portValidationMessage: String? {
        guard !trimmedPortText.isEmpty else {
            return focusedField == .serverPort ? nil : "Enter a port from 1 to 65535."
        }
        return isPortDraftValid ? nil : "Port must be from 1 to 65535."
    }

    private func syncPortText() {
        if portText.isEmpty || (!hasUnsavedPortChange && focusedField != .serverPort) {
            portText = String(localServer.preferredPort)
        }
    }

    private func filterPortInput(_ value: String) {
        let filtered = String(value.filter(\.isNumber).prefix(5))
        if filtered != value {
            portText = filtered
        }
    }

    private func applyPortChange() {
        _ = savePortDraft(restartIfRunning: true)
    }

    @discardableResult
    private func savePortDraft(restartIfRunning: Bool) -> Bool {
        guard let port = portDraftValue else {
            syncPortText()
            return false
        }

        focusedField = nil
        let needsRestart = restartIfRunning && localServer.isRunning && port != localServer.port
        localServer.preferredPort = port
        portText = String(port)

        guard needsRestart else {
            return true
        }

        isApplyingPort = true
        serverHealthy = nil
        Task {
            await localServer.restartAsync()
            let healthy = await localServer.checkServerHealth()
            await MainActor.run {
                serverHealthy = healthy
                isApplyingPort = false
                syncPortText()
            }
        }
        return true
    }
}

// MARK: - Provider Picker
private struct DebridProviderPickerView: View {
    @Binding var selectedProvider: String
    let onDone: () -> Void

    var body: some View {
        StreamifyPickerShell(
            title: "Debrid",
            trailingTitle: "Done",
            trailingAction: onDone
        ) {
            ForEach(TorrentioService.DebridProvider.allCases) { provider in
                Button {
                    selectedProvider = provider.rawValue
                    onDone()
                } label: {
                    HStack {
                        Text(provider.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        if selectedProvider == provider.rawValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                .streamifyPickerRow(selected: selectedProvider == provider.rawValue)
            }
        }
    }
}

// MARK: - Language Picker Sheet
struct LanguagePickerSheet: View {
    @Binding var selectedLanguages: Set<String>
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filteredLanguages: [(name: String, code: String)] {
        if searchText.isEmpty { return LanguageSupport.commonLanguages }
        return LanguageSupport.commonLanguages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.code.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        StreamifyPickerShell(
            title: "Preferred Languages",
            trailingTitle: "Done",
            trailingAction: {
                if let onDone {
                    onDone()
                } else {
                    dismiss()
                }
            }
        ) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(StreamifyPopupPalette.secondaryText)
                TextField("Search languages", text: $searchText)
            }
            .streamifyTextInput()

            ForEach(filteredLanguages, id: \.code) { lang in
                let isSelected = selectedLanguages.contains(lang.name)
                Button {
                    if isSelected {
                        if selectedLanguages.count > 1 {
                            selectedLanguages.remove(lang.name)
                        }
                    } else {
                        selectedLanguages.insert(lang.name)
                    }
                } label: {
                    HStack {
                        Text(lang.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                        Text(lang.code)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StreamifyPopupPalette.secondaryText)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                                .font(.body.weight(.semibold))
                        }
                    }
                    .streamifyPickerButtonLabel()
                }
                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                .streamifyPickerRow(selected: isSelected)
            }
        }
    }
}

// MARK: - Genre Picker Sheet
struct GenrePickerSheet: View {
    @Binding var selectedGenres: Set<Genre>
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StreamifyPickerShell(
            title: "Preferred Genres",
            trailingTitle: "Done",
            trailingAction: close
        ) {
            Text("Pick genres for Home rows and featured recommendations")
                .streamifyPickerDescription()

            ForEach(StreamifyPreferences.selectableGenres) { genre in
                let isSelected = selectedGenres.contains(genre)
                Button {
                    if isSelected {
                        selectedGenres.remove(genre)
                    } else {
                        selectedGenres.insert(genre)
                    }
                } label: {
                    HStack {
                        Text(genre.rawValue)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                                .font(.body.weight(.semibold))
                        }
                    }
                    .streamifyPickerButtonLabel()
                }
                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                .streamifyPickerRow(selected: isSelected)
            }
        }
    }

    private func close() {
        if let onDone {
            onDone()
        } else {
            dismiss()
        }
    }
}

// MARK: - Single Language Picker Sheet (for DeveloperView)
struct SingleLanguagePickerSheet: View {
    @Binding var selectedCode: String
    @Binding var selectedName: String
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var useCustom: Bool = false
    @State private var customName: String = ""
    @State private var customCode: String = ""

    private var filteredLanguages: [(name: String, code: String)] {
        if searchText.isEmpty { return LanguageSupport.commonLanguages }
        return LanguageSupport.commonLanguages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.code.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        StreamifyPickerShell(
            title: "Select Language",
            leadingTitle: "Cancel",
            leadingAction: close
        ) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(StreamifyPopupPalette.secondaryText)
                TextField("Search languages", text: $searchText)
            }
            .streamifyTextInput()

            ForEach(filteredLanguages, id: \.code) { lang in
                let isSelected = !useCustom && selectedCode == lang.code
                Button {
                    useCustom = false
                    selectedCode = lang.code
                    selectedName = lang.name
                    close()
                } label: {
                    HStack {
                        Text(lang.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                        Text(lang.code)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StreamifyPopupPalette.secondaryText)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                                .font(.body.weight(.semibold))
                        }
                    }
                    .streamifyPickerButtonLabel()
                }
                .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                .streamifyPickerRow(selected: isSelected)
            }

            Text("Custom")
                .streamifyPickerSectionTitle()

            Button {
                useCustom = true
            } label: {
                HStack {
                    Text("Custom Language")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    if useCustom {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.white)
                            .font(.body.weight(.semibold))
                    }
                }
                .streamifyPickerButtonLabel()
            }
            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
            .streamifyPickerRow(selected: useCustom)

            if useCustom {
                VStack(spacing: 10) {
                    TextField("Language Name", text: $customName)
                        .streamifyTextInput()

                    TextField("Language ID (e.g. en)", text: $customCode)
                        .streamifyTextInput()

                    Button("Apply") {
                        if !customName.isEmpty && !customCode.isEmpty {
                            selectedName = customName
                            selectedCode = customCode
                            close()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity((customName.isEmpty || customCode.isEmpty) ? 0.42 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
                    .disabled(customName.isEmpty || customCode.isEmpty)
                }
                .padding(.top, 2)
            }
        }
        .onAppear {
            if !selectedCode.isEmpty {
                let isKnown = LanguageSupport.commonLanguages.contains { $0.code == selectedCode }
                if !isKnown {
                    useCustom = true
                    customName = selectedName
                    customCode = selectedCode
                }
            }
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}
