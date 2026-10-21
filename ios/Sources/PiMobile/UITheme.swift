import SwiftUI

// Shared design tokens and UI components for PiMobile following Apple
// Human Interface Guidelines: fluid spring motion, translucent materials,
// clear visual hierarchy, and tactile feedback.

public enum PiTheme {
    // MARK: - Springs (Apple WWDC 2018 Fluid Interfaces)
    // Response: quick settle time. Damping: 1.0 for zero overshoot, 0.82 for subtle momentum.
    public static let fluidSpring = Animation.spring(response: 0.38, dampingFraction: 1.0)
    public static let snappySpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    public static let bounceSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    // MARK: - Colors & Brushes
    public static let canvas = Color(red: 0.05, green: 0.05, blue: 0.07)
    public static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    public static let subtleBorder = Color.primary.opacity(0.08)
    public static let cardBorder = Color.white.opacity(0.06)

    public static let userBubbleGradient = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Reusable View Modifiers

public struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 12

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(PiTheme.subtleBorder, lineWidth: 0.8)
            )
    }
}

public struct SurfaceCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 14

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(PiTheme.subtleBorder, lineWidth: 0.8)
            )
    }
}

public extension View {
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 12) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    func surfaceCard(cornerRadius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        modifier(SurfaceCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Shared Badges & Pills

public struct StatusPill: View {
    public enum State {
        case idle, running, success, error, warning
    }

    public let state: State
    public let text: String

    public init(_ state: State, text: String) {
        self.state = state
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 5) {
            dot
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tintColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tintColor.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var dot: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(tintColor)
        case .idle:
            Circle().fill(.secondary).frame(width: 6, height: 6)
        case .success:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .error:
            Circle().fill(Color.red).frame(width: 6, height: 6)
        case .warning:
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        }
    }

    private var tintColor: Color {
        switch state {
        case .running: .blue
        case .idle: .secondary
        case .success: .green
        case .error: .red
        case .warning: .orange
        }
    }
}
