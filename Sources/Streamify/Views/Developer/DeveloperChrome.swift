import SwiftUI

struct DeveloperSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        StreamifySectionHeader(title: title)
    }
}

struct DeveloperActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                StreamifyIconWell(icon: icon, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.gray)
                }

                Spacer()
            }
            .padding(14)
            .streamifyPanel(cornerRadius: 10)
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
    }
}

struct DeveloperAddButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.98))
    }
}
