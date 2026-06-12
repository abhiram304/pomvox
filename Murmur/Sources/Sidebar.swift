import SwiftUI

struct Sidebar: View {
    @Binding var selection: NavItem
    @EnvironmentObject var model: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // brand
            HStack(spacing: 9) {
                Waveform()
                Text("Murmur").font(Typo.display(22)).foregroundStyle(Palette.ink)
            }
            .padding(.leading, 10).padding(.top, 6).padding(.bottom, 18)

            // nav
            VStack(spacing: 2) {
                ForEach(NavItem.allCases) { item in
                    NavRow(item: item, selected: selection == item) { selection = item }
                }
            }

            Spacer(minLength: 12)

            StatusChip()
            PrivacyFooter()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

private struct NavRow: View {
    let item: NavItem
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(item.title).font(Typo.ui(13.5, .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Palette.ember : Palette.inkSoft)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Palette.sel : (hovering ? Palette.pane2 : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StatusChip: View {
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 4).scaleEffect(1.6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Ready to dictate").font(Typo.ui(12, .semibold)).foregroundStyle(Palette.ink)
                Text("Hold Fn · or Fn + Space").font(Typo.ui(11)).foregroundStyle(Palette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hair, lineWidth: 0.5))
        .padding(.bottom, 10)
    }
}

private struct PrivacyFooter: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text("Everything stays on this Mac.").font(Typo.ui(11)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 6)
    }
}

/// The signature mark — a small live waveform that ties the Hub to the
/// dictation HUD. Five bars breathing on a staggered loop.
struct Waveform: View {
    @State private var animate = false
    private let heights: [CGFloat] = [7, 15, 20, 11, 6]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(Palette.ember)
                    .frame(width: 2.5, height: heights[i])
                    .scaleEffect(y: animate ? 1 : 0.5, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: animate)
            }
        }
        .frame(height: 20)
        .onAppear { animate = true }
    }
}
