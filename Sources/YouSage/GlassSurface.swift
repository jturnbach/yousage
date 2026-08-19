import SwiftUI

/// Liquid Glass where the OS has it, a plain material where it does not.
///
/// `.glassEffect` arrived in macOS 26. YouSage deploys to macOS 14, so every
/// glass surface has to fork. Keeping the fork in one modifier means the views
/// never spell `#available` themselves, and the fallback stays a real design
/// rather than an afterthought: a material pane with a hairline edge, which is
/// what these panes looked like before glass existed.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 16

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

/// A titled pane of glass.
///
/// Replaces `GroupBox`, whose opaque fill sits on top of a glass window instead
/// of in it.
struct GlassCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 16)
    }
}

/// Groups sibling panes so the system can blend their edges and share one
/// refraction pass, rather than stacking several independent sheets of glass.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
