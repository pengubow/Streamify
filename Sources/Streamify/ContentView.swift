import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var libraryViewModel = LibraryViewModel()
    @State private var selectedTab: Tab = .library
    @State private var stableViewportHeight: CGFloat = 0
    @State private var keyboardIsVisible: Bool = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    enum Tab: Int, CaseIterable {
        case library
        case downloads
        case settings
    }

    var body: some View {
        GeometryReader { proxy in
            let tabShellHeight = keyboardIsVisible
                ? max(stableViewportHeight, proxy.size.height)
                : proxy.size.height
            let bottomInset = StreamifySafeArea.bottomChromeInset(
                max(proxy.safeAreaInsets.bottom, deviceBottomSafeAreaInset)
            )

            ZStack(alignment: .top) {
                StreamifyTabPage(tab: .library, selectedTab: $selectedTab, width: proxy.size.width) {
                    LibraryView(viewModel: libraryViewModel)
                }

                StreamifyTabPage(tab: .downloads, selectedTab: $selectedTab, width: proxy.size.width) {
                    DownloadsView()
                }

                StreamifyTabPage(tab: .settings, selectedTab: $selectedTab, width: proxy.size.width) {
                    SettingsView(viewModel: libraryViewModel)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CustomTabBar(
                        selectedTab: $selectedTab,
                        bottomInset: bottomInset
                    )
                }
                .ignoresSafeArea(edges: .bottom)
                .zIndex(100)
            }
            .frame(width: proxy.size.width, height: tabShellHeight, alignment: .top)
            .ignoresSafeArea(.keyboard, edges: .all)
            .onAppear {
                stableViewportHeight = proxy.size.height
            }
            .onChange(of: proxy.size.height) { nextHeight in
                if keyboardIsVisible {
                    stableViewportHeight = max(stableViewportHeight, nextHeight)
                } else {
                    stableViewportHeight = nextHeight
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.03), value: selectedTab)
        .tint(.white)
        .preferredColorScheme(.dark)
        .streamifyScrollIndicatorsHidden()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            StreamifyOnboardingView {
                hasCompletedOnboarding = true
            }
            .interactiveDismissDisabled()
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding },
            set: { isPresented in
                if !isPresented {
                    hasCompletedOnboarding = true
                }
            }
        )
    }

    private var deviceBottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }
}

// Each page observes selection directly so the GeometryReader's deferred content
// does not have to be rebuilt for a tab change to reach its visibility modifiers.
private struct StreamifyTabPage<Content: View>: View {
    let tab: ContentView.Tab
    @Binding var selectedTab: ContentView.Tab
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(x: offset)
            .opacity(tab == selectedTab ? 1 : 0)
            .zIndex(tab == selectedTab ? 2 : 1)
            .allowsHitTesting(tab == selectedTab)
            .accessibilityHidden(tab != selectedTab)
    }

    private var offset: CGFloat {
        guard tab != selectedTab else { return 0 }
        return tab.rawValue < selectedTab.rawValue ? -width : width
    }
}

// MARK: - Custom Tab Bar to prevent animation issues
struct CustomTabBar: View {
    @Binding var selectedTab: ContentView.Tab
    let bottomInset: CGFloat
    
    var body: some View {
        HStack(spacing: 0) {
            TabBarButton(
                icon: "house.fill",
                label: "Home",
                isSelected: selectedTab == .library
            ) {
                selectTab(.library)
            }
            
            TabBarButton(
                icon: "arrow.down.circle",
                label: "Downloads",
                isSelected: selectedTab == .downloads
            ) {
                selectTab(.downloads)
            }
            
            TabBarButton(
                icon: "gearshape",
                label: "Settings",
                isSelected: selectedTab == .settings
            ) {
                selectTab(.settings)
            }
        }
        .padding(.top, 7)
        .padding(.bottom, bottomInset)
        .background {
            StreamifyBarMaterial(edges: .bottom)
        }
        .overlay(alignment: .top) {
            StreamifyBarHairline()
        }
    }

    private func selectTab(_ tab: ContentView.Tab) {
        guard tab != selectedTab else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.03)) {
            selectedTab = tab
        }
    }
}

// MARK: - Tab Bar Button
struct TabBarButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : .gray)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.94))
    }
}
