import SwiftUI

enum StreamifySurface {
    static let pageBase = Color.black
    static let pageTop = Color(white: 0.11)
    static let panelFill = Color(white: 0.16).opacity(0.72)
    static let panelStroke = Color.white.opacity(0.08)
    static let panelHairline = Color.white.opacity(0.10)
    static let navigationBar = Color(white: 0.16).opacity(0.92)
    static let mutedText = Color.white.opacity(0.58)
}

struct StreamifyPageBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                StreamifySurface.pageTop,
                StreamifySurface.pageBase,
                StreamifySurface.pageBase
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct StreamifySectionHeader: View {
    let title: String
    var tint: Color = .white

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StreamifyEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = .white.opacity(0.72)

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background(StreamifySurface.panelFill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StreamifySurface.panelStroke, lineWidth: 1)
                }

            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(StreamifySurface.mutedText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
    }
}

struct StreamifyIconWell: View {
    let icon: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: icon)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StreamifyPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let materialOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                if materialOpacity > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                        .opacity(materialOpacity)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(StreamifySurface.panelFill)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(StreamifySurface.panelStroke, lineWidth: 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(StreamifySurface.panelFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(StreamifySurface.panelStroke, lineWidth: 1)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func streamifyPanel(cornerRadius: CGFloat = 10, materialOpacity: Double = 0.28) -> some View {
        modifier(StreamifyPanelModifier(cornerRadius: cornerRadius, materialOpacity: materialOpacity))
    }

    func streamifyNavigationChrome() -> some View {
        streamifyNavigationBarChrome()
    }
}
