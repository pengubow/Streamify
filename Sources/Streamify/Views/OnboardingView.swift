import SwiftUI

struct StreamifyOnboardingView: View {
    let onFinish: () -> Void

    @AppStorage("preferredSubtitleLanguages") private var preferredSubtitleLanguages: String = "English"
    @AppStorage("preferredAudioLanguages") private var preferredAudioLanguages: String = "English"
    @AppStorage("preferredGenres") private var preferredGenresRaw: String = ""
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

    @State private var selectedLanguages: Set<String> = []
    @State private var selectedGenres: Set<Genre> = []
    @State private var selectedVidLinkEnabled: Bool = true
    @State private var selectedMovies111Enabled: Bool = true
    @State private var selectedTorrentioEnabled: Bool = false
    @State private var selectedTorrentioDebridProviderRaw: String = TorrentioService.DebridProvider.realdebrid.rawValue
    @State private var selectedRealDebridApiKey: String = ""
    @State private var selectedPremiumizeApiKey: String = ""
    @State private var selectedAllDebridApiKey: String = ""
    @State private var selectedDebridLinkApiKey: String = ""
    @State private var selectedEasyDebridApiKey: String = ""
    @State private var selectedOffcloudApiKey: String = ""
    @State private var selectedTorBoxApiKey: String = ""
    @State private var selectedPutioClientId: String = ""
    @State private var selectedPutioToken: String = ""

    private let suggestedLanguages = LanguageSupport.suggestedLanguages

    private let selectionColumns = [
        GridItem(.adaptive(minimum: 104), spacing: 8)
    ]

    private var selectedTorrentioDebridProvider: TorrentioService.DebridProvider {
        TorrentioService.DebridProvider(rawValue: selectedTorrentioDebridProviderRaw) ?? .realdebrid
    }

    private var selectableDebridProviders: [TorrentioService.DebridProvider] {
        TorrentioService.DebridProvider.allCases.filter { $0 != .none }
    }

    private var isSelectedDebridConfigured: Bool {
        switch selectedTorrentioDebridProvider {
        case .none:
            return false
        case .putio:
            return !selectedPutioClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !selectedPutioToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !torrentioDebridKey(for: selectedTorrentioDebridProvider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    var body: some View {
        ZStack {
            StreamifyPageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    languagesSection
                    genresSection
                    providersSection
                    actionSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedLanguages = StreamifyPreferences.languages(from: preferredSubtitleLanguages)
            if selectedLanguages.isEmpty {
                selectedLanguages = ["English"]
            }
            selectedGenres = StreamifyPreferences.genres(from: preferredGenresRaw)
            selectedVidLinkEnabled = vidLinkEnabled
            selectedMovies111Enabled = movies111Enabled
            selectedTorrentioEnabled = torrentioEnabled
            selectedTorrentioDebridProviderRaw = torrentioDebridProvider
            selectedRealDebridApiKey = torrentioRealDebridApiKey
            selectedPremiumizeApiKey = torrentioPremiumizeApiKey
            selectedAllDebridApiKey = torrentioAllDebridApiKey
            selectedDebridLinkApiKey = torrentioDebridLinkApiKey
            selectedEasyDebridApiKey = torrentioEasyDebridApiKey
            selectedOffcloudApiKey = torrentioOffcloudApiKey
            selectedTorBoxApiKey = torrentioTorBoxApiKey
            selectedPutioClientId = torrentioPutioClientId
            selectedPutioToken = torrentioPutioToken
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            StreamifyIconWell(icon: "play.rectangle.fill", tint: .red)
                .scaleEffect(1.18)
                .padding(.bottom, 4)

            Text("Set up Streamify")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text("Pick what you like once. Home, featured picks, downloads, and playback will use the same preferences.")
                .font(.subheadline)
                .foregroundStyle(StreamifySurface.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
    }

    private var languagesSection: some View {
        onboardingPanel(title: "Languages", subtitle: "Used for audio and subtitles when streams expose choices.") {
            LazyVGrid(columns: selectionColumns, spacing: 8) {
                ForEach(suggestedLanguages, id: \.self) { language in
                    onboardingTile(
                        title: language,
                        isSelected: selectedLanguages.contains(language)
                    ) {
                        if selectedLanguages.contains(language) {
                            if selectedLanguages.count > 1 {
                                selectedLanguages.remove(language)
                            }
                        } else {
                            selectedLanguages.insert(language)
                        }
                    }
                }
            }
        }
    }

    private var genresSection: some View {
        onboardingPanel(title: "Genres", subtitle: "Home and the featured card will bias toward these TMDB genres.") {
            LazyVGrid(columns: selectionColumns, spacing: 8) {
                ForEach(StreamifyPreferences.selectableGenres) { genre in
                    onboardingTile(
                        title: genre.rawValue,
                        isSelected: selectedGenres.contains(genre)
                    ) {
                        if selectedGenres.contains(genre) {
                            selectedGenres.remove(genre)
                        } else {
                            selectedGenres.insert(genre)
                        }
                    }
                }
            }
        }
    }

    private var providersSection: some View {
        onboardingPanel(title: "Sources", subtitle: "Choose the online providers Streamify should try while resolving playback.") {
            VStack(spacing: 12) {
                onboardingToggle(title: "VidLink", subtitle: "Fast online HLS source", isOn: $selectedVidLinkEnabled, tint: .blue)
                onboardingToggle(title: "111Movies", subtitle: "Alternative online HLS source", isOn: $selectedMovies111Enabled, tint: .purple)
                onboardingToggle(title: "Torrentio", subtitle: "Stremio/Torrentio streams, best with debrid", isOn: $selectedTorrentioEnabled, tint: .orange)

                if selectedTorrentioEnabled {
                    torrentioSetupSection
                }
            }
        }
    }

    private var torrentioSetupSection: some View {
        VStack(spacing: 10) {
            Menu {
                ForEach(selectableDebridProviders) { provider in
                    Button(provider.displayName) {
                        selectedTorrentioDebridProviderRaw = provider.rawValue
                    }
                }
            } label: {
                HStack {
                    Text("Debrid")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(selectedTorrentioDebridProvider.displayName)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(StreamifyPopupPalette.rowSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if selectedTorrentioDebridProvider == .putio {
                onboardingSecureField("Put.io Client ID", text: $selectedPutioClientId)
                onboardingSecureField("Put.io Token", text: $selectedPutioToken)
            } else {
                onboardingSecureField(
                    "\(selectedTorrentioDebridProvider.displayName) API key",
                    text: torrentioDebridKeyBinding(for: selectedTorrentioDebridProvider)
                )
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(isSelectedDebridConfigured ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(isSelectedDebridConfigured ? "Torrentio will be enabled" : "Torrentio stays off until credentials are added")
                    .font(.caption)
                    .foregroundStyle(isSelectedDebridConfigured ? .green : .orange)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.16), lineWidth: 1)
        }
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            Button {
                complete(saveSelections: true)
            } label: {
                Text("Start Watching")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.97))

            Button {
                complete(saveSelections: false)
            } label: {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StreamifySurface.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.97))
        }
        .padding(.top, 4)
    }

    private func onboardingPanel<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StreamifySurface.mutedText)
            }

            content()
        }
        .padding(16)
        .streamifyPanel(cornerRadius: 12)
    }

    private func onboardingTile(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 42)

                Circle()
                    .fill(isSelected ? Color.white : Color.clear)
                    .frame(width: 6, height: 6)
                    .padding(8)
            }
            .foregroundStyle(.white)
            .background(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.04), lineWidth: 1)
            }
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.96))
    }

    private func onboardingToggle(title: String, subtitle: String, isOn: Binding<Bool>, tint: Color) -> some View {
        HStack(spacing: 12) {
            StreamifyIconWell(icon: isOn.wrappedValue ? "checkmark.circle.fill" : "circle", tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StreamifySurface.mutedText)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(12)
        .background(StreamifyPopupPalette.rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func onboardingSecureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .streamifyTextInput()
    }

    private func torrentioDebridKey(for provider: TorrentioService.DebridProvider) -> String {
        switch provider {
        case .none, .putio:
            return ""
        case .realdebrid:
            return selectedRealDebridApiKey
        case .premiumize:
            return selectedPremiumizeApiKey
        case .alldebrid:
            return selectedAllDebridApiKey
        case .debridlink:
            return selectedDebridLinkApiKey
        case .easydebrid:
            return selectedEasyDebridApiKey
        case .offcloud:
            return selectedOffcloudApiKey
        case .torbox:
            return selectedTorBoxApiKey
        }
    }

    private func torrentioDebridKeyBinding(for provider: TorrentioService.DebridProvider) -> Binding<String> {
        switch provider {
        case .none, .putio:
            return .constant("")
        case .realdebrid:
            return $selectedRealDebridApiKey
        case .premiumize:
            return $selectedPremiumizeApiKey
        case .alldebrid:
            return $selectedAllDebridApiKey
        case .debridlink:
            return $selectedDebridLinkApiKey
        case .easydebrid:
            return $selectedEasyDebridApiKey
        case .offcloud:
            return $selectedOffcloudApiKey
        case .torbox:
            return $selectedTorBoxApiKey
        }
    }

    private func complete(saveSelections: Bool) {
        if saveSelections {
            let shouldEnableTorrentio = selectedTorrentioEnabled && isSelectedDebridConfigured
            let languageRawValue = StreamifyPreferences.rawValue(forLanguages: selectedLanguages)
            preferredSubtitleLanguages = languageRawValue
            preferredAudioLanguages = languageRawValue
            preferredGenresRaw = StreamifyPreferences.rawValue(forGenres: selectedGenres)
            vidLinkEnabled = selectedVidLinkEnabled
            movies111Enabled = selectedMovies111Enabled
            torrentioEnabled = shouldEnableTorrentio
            torrentioDebridProvider = selectedTorrentioDebridProviderRaw
            torrentioRealDebridApiKey = selectedRealDebridApiKey
            torrentioPremiumizeApiKey = selectedPremiumizeApiKey
            torrentioAllDebridApiKey = selectedAllDebridApiKey
            torrentioDebridLinkApiKey = selectedDebridLinkApiKey
            torrentioEasyDebridApiKey = selectedEasyDebridApiKey
            torrentioOffcloudApiKey = selectedOffcloudApiKey
            torrentioTorBoxApiKey = selectedTorBoxApiKey
            torrentioPutioClientId = selectedPutioClientId
            torrentioPutioToken = selectedPutioToken
        }
        onFinish()
    }
}
