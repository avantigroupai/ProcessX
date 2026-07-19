import SwiftUI

/// Selectable look. Each theme restyles the whole window: background, card
/// treatment, accent gradient, and whether it uses Liquid Glass.
enum AppTheme: String, CaseIterable, Identifiable {
    case liquidGlass = "Liquid Glass"
    case graphite    = "Graphite"
    case midnight    = "Midnight"
    case aurora      = "Aurora"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .liquidGlass: return "circle.hexagongrid"
        case .graphite:    return "square.grid.2x2"
        case .midnight:    return "moon.stars"
        case .aurora:      return "sparkles"
        }
    }

    var forcedScheme: ColorScheme? {
        switch self {
        case .graphite: return nil          // follows the system
        default:        return .dark
        }
    }

    /// Ring / bar gradient poles.
    var accent: Color {
        switch self {
        // Apple's canonical dark-mode system blue (#0A84FF). A purer blue than the
        // old azure — its green channel was high enough that the Liquid Glass
        // specular edge on .glassProminent read as a green/cyan rim.
        case .liquidGlass: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .graphite:    return Color(red: 0.34, green: 0.44, blue: 0.92)
        case .midnight:    return Color(red: 0.30, green: 0.86, blue: 0.92)
        case .aurora:      return Color(red: 0.98, green: 0.42, blue: 0.82)
        }
    }
    var accent2: Color {
        switch self {
        // A lighter tint of the same system blue for the gauge gradient — kept
        // blue, not cyan, so glass refraction near the button stays clean.
        case .liquidGlass: return Color(red: 0.36, green: 0.68, blue: 1.0)
        case .graphite:    return Color(red: 0.51, green: 0.60, blue: 1.0)
        case .midnight:    return Color(red: 0.46, green: 0.52, blue: 1.0)
        case .aurora:      return Color(red: 0.40, green: 0.74, blue: 1.0)
        }
    }

    var usesGlass: Bool { self == .liquidGlass }

    /// Track colour behind a gauge ring / meter.
    var gaugeTrack: Color {
        switch self {
        case .graphite: return Color.primary.opacity(0.10)
        default:        return Color.white.opacity(0.09)
        }
    }
}

// MARK: - background

struct ThemeBackground: View {
    let theme: AppTheme
    var body: some View {
        switch theme {
        case .liquidGlass:
            ZStack {
                Rectangle().fill(.background)
                LinearGradient(colors: [theme.accent.opacity(0.20), .clear],
                               startPoint: .topLeading, endPoint: .center)
                LinearGradient(colors: [.clear, theme.accent2.opacity(0.14)],
                               startPoint: .center, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        case .graphite:
            Rectangle().fill(.background).ignoresSafeArea()
        case .midnight:
            ZStack {
                Color(red: 0.035, green: 0.035, blue: 0.05)
                RadialGradient(colors: [theme.accent.opacity(0.16), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 620)
                RadialGradient(colors: [theme.accent2.opacity(0.13), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 720)
            }.ignoresSafeArea()
        case .aurora:
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.05, blue: 0.17),
                                        Color(red: 0.05, green: 0.07, blue: 0.16),
                                        Color(red: 0.03, green: 0.10, blue: 0.13)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [theme.accent.opacity(0.22), .clear],
                               center: .init(x: 0.15, y: 0.0), startRadius: 0, endRadius: 520)
                RadialGradient(colors: [theme.accent2.opacity(0.20), .clear],
                               center: .init(x: 0.9, y: 0.85), startRadius: 0, endRadius: 620)
            }.ignoresSafeArea()
        }
    }
}

// MARK: - card treatment

private struct ThemedCard: ViewModifier {
    let theme: AppTheme
    let radius: CGFloat
    func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass:
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        case .graphite:
            content
                .background(.regularMaterial, in: .rect(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        case .midnight:
            content
                .background(RoundedRectangle(cornerRadius: radius)
                    .fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(theme.accent.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
        case .aurora:
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(colors: [theme.accent.opacity(0.5), theme.accent2.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1))
        }
    }
}

extension View {
    func themedCard(_ theme: AppTheme, radius: CGFloat = 24) -> some View {
        modifier(ThemedCard(theme: theme, radius: radius))
    }
}
