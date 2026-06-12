import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: HubModel
    @State private var query = ""

    private var results: [Dictation] { model.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "History") {
                SearchField(text: $query)
            }
            metaBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        EmptyResults(searching: !query.isEmpty)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, d in
                            DictationRow(dictation: d, dateStyle: .calendar, showDelete: true)
                            if idx < results.count - 1 { Divider().overlay(Palette.hair) }
                        }
                    }
                }
            }
        }
    }

    private var metaBar: some View {
        HStack(spacing: 10) {
            Text("\(model.rows.count) dictations").font(Typo.ui(12.5)).foregroundStyle(Palette.muted)
            Chip(text: "Kept 7 days, then auto-deleted", systemImage: "clock.arrow.circlepath")
            Chip(text: "Text only · never audio", systemImage: "waveform.slash")
            Spacer()
            Chip(text: "Delete all", danger: true)
        }
        .padding(.horizontal, 34).padding(.vertical, 14)
        .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
    }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Search dictations…", text: $text)
                .textFieldStyle(.plain).font(Typo.ui(13)).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 10).frame(width: 240, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pane2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair, lineWidth: 0.5))
    }
}

private struct EmptyResults: View {
    let searching: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: searching ? "text.magnifyingglass" : "clock")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted)
            Text(searching ? "No matches" : "No dictations yet")
                .font(Typo.display(18)).foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}
