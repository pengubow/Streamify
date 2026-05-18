import SwiftUI
import UIKit

/// A reusable custom time picker for hours, minutes, and seconds.
/// Stores the underlying value as total seconds (String). Max is 23:59:59.
struct TimeInputField: View {
    let label: String
    @Binding var totalSeconds: String
    var caption: String? = nil
    
    private var seconds: Int { Int(Double(totalSeconds) ?? 0) }
    private var hours: Int { seconds / 3600 }
    private var minutes: Int { (seconds % 3600) / 60 }
    private var secs: Int { seconds % 60 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.gray)

            HStack(spacing: 6) {
                TimeWheelColumn(unit: "h", range: 0...23, selection: hoursBinding, format: "%d")
                TimeWheelColumn(unit: "m", range: 0...59, selection: minutesBinding)
                TimeWheelColumn(unit: "s", range: 0...59, selection: secondsBinding)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(6)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }

            if let caption = caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
        }
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { hours },
            set: { updateTime(hours: $0, minutes: minutes, seconds: secs) }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { minutes },
            set: { updateTime(hours: hours, minutes: $0, seconds: secs) }
        )
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { secs },
            set: { updateTime(hours: hours, minutes: minutes, seconds: $0) }
        )
    }

    private func updateTime(hours: Int, minutes: Int, seconds: Int) {
        let total = hours * 3600 + minutes * 60 + seconds
        totalSeconds = String(total)
    }
}

struct TimeInputPair: View {
    let firstLabel: String
    @Binding var firstValue: String
    let secondLabel: String
    @Binding var secondValue: String

    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                horizontalFields
                verticalFields
            }
        } else {
            verticalFields
        }
    }

    private var horizontalFields: some View {
        HStack(spacing: 16) {
            TimeInputField(label: firstLabel, totalSeconds: $firstValue)
            TimeInputField(label: secondLabel, totalSeconds: $secondValue)
        }
    }

    private var verticalFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimeInputField(label: firstLabel, totalSeconds: $firstValue)
            TimeInputField(label: secondLabel, totalSeconds: $secondValue)
        }
    }
}

private struct TimeWheelColumn: View {
    let unit: String
    let range: ClosedRange<Int>
    @Binding var selection: Int
    var format: String = "%02d"

    private let rowHeight: CGFloat = 34
    private let columnWidth: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .frame(height: rowHeight)

            Picker(unit, selection: $selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(String(format: format, value))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(width: columnWidth, height: rowHeight * 3.5)
            .clipped()
            .compositingGroup()
            .mask(wheelFadeMask)
            .onChange(of: selection) { _ in
                UISelectionFeedbackGenerator().selectionChanged()
            }

            VStack {
                Spacer()
                Text(unit)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 9)
            }
            .allowsHitTesting(false)
        }
        .frame(width: columnWidth, height: rowHeight * 3.5)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var wheelFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.18), location: 0.16),
                .init(color: .black, location: 0.36),
                .init(color: .black, location: 0.64),
                .init(color: .black.opacity(0.18), location: 0.84),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
