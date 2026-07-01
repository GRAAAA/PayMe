import SwiftUI

enum PayMeTheme {
    static let coral = Color(red: 0.98, green: 0.33, blue: 0.25)
    static let peach = Color(red: 1.0, green: 0.91, blue: 0.86)
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let muted = Color(red: 0.46, green: 0.45, blue: 0.49)
    static let canvas = Color(uiColor: .systemGroupedBackground)
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(PayMeTheme.coral.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
