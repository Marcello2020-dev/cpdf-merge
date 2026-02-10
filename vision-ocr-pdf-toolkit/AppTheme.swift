import SwiftUI
import AppKit

enum AppTheme {
    static let primaryAccent = Color("AccentColor")
    static let secondaryAccent = Color("SecondaryAccent")

    static let windowGradient = LinearGradient(
        colors: [
            primaryAccent.opacity(0.10),
            secondaryAccent.opacity(0.12),
            primaryAccent.opacity(0.06)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panelGradient = LinearGradient(
        colors: [
            primaryAccent.opacity(0.12),
            secondaryAccent.opacity(0.16),
            primaryAccent.opacity(0.10)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let pdfCanvasBackground = NSColor(
        red: 0.09,
        green: 0.27,
        blue: 0.42,
        alpha: 0.22
    )

    static func applyWindowChrome(_ window: NSWindow) {
        let tintColor = NSColor(
            red: 0.09,
            green: 0.33,
            blue: 0.52,
            alpha: 1.0
        )
        let baseColor = NSColor.windowBackgroundColor
        window.backgroundColor = baseColor.blended(withFraction: 0.22, of: tintColor) ?? baseColor
        window.isOpaque = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
    }
}

struct WindowThemeApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            AppTheme.applyWindowChrome(window)
        }
    }
}

struct AppActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let fillStyle: AnyShapeStyle = {
            if isEnabled {
                return AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            AppTheme.primaryAccent.opacity(colorScheme == .dark ? 0.94 : 0.90),
                            AppTheme.secondaryAccent.opacity(colorScheme == .dark ? 0.86 : 0.82)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            return AnyShapeStyle(Color.secondary.opacity(colorScheme == .dark ? 0.24 : 0.18))
        }()

        let labelColor: Color = {
            guard isEnabled else { return .secondary.opacity(0.85) }
            return colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.84)
        }()

        let strokeColor: Color = {
            guard isEnabled else { return .secondary.opacity(0.30) }
            return colorScheme == .dark
                ? AppTheme.secondaryAccent.opacity(0.72)
                : AppTheme.primaryAccent.opacity(0.90)
        }()

        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fillStyle)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1.0)
            }
            .scaleEffect(pressed ? 0.985 : 1.0)
            .opacity(pressed ? 0.93 : 1.0)
            .shadow(
                color: isEnabled
                    ? (colorScheme == .dark ? .black.opacity(0.35) : .black.opacity(0.18))
                    : .clear,
                radius: pressed ? 1 : 2,
                y: pressed ? 0 : 1
            )
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
