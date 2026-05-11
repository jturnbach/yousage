import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if let pct = state.displayPercent, state.isConfigured {
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private var iconName: String {
        guard state.isConfigured else { return "gauge.with.dots.needle.0percent" }
        if state.lastError != nil && state.snapshot == nil {
            return "exclamationmark.triangle.fill"
        }
        let pct = state.displayPercent ?? 0
        switch pct {
        case ..<25:  return "gauge.with.dots.needle.0percent"
        case 25..<50: return "gauge.with.dots.needle.33percent"
        case 50..<75: return "gauge.with.dots.needle.50percent"
        case 75..<95: return "gauge.with.dots.needle.67percent"
        default:      return "gauge.with.dots.needle.100percent"
        }
    }
}
