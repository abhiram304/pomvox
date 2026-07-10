import AppKit
import SwiftUI

/// Builds the `mailto:` link the "Report an Issue" screen hands to the user's
/// mail client. Pomvox has no account and sends nothing itself — submitting
/// opens the default mail app with the message pre-addressed to the maintainer,
/// and the user presses send there (so their own return address is used, and no
/// SMTP credentials live in the app).
///
/// Pure logic (fields → URL) so the encoding is unit-tested; opening the URL is
/// the thin shell in the view.
enum ReportIssue {
    static let recipient = "hello@pomvox.ai"

    /// A `mailto:` URL for the given fields. Subject/body are optional — an empty
    /// value is simply omitted from the query so the composer opens blank there.
    static func mailtoURL(to: String = recipient, subject: String, body: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = to
        var items: [URLQueryItem] = []
        if !subject.isEmpty { items.append(URLQueryItem(name: "subject", value: subject)) }
        if !body.isEmpty { items.append(URLQueryItem(name: "body", value: body)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }
}

/// A lightweight compose screen for sending feedback to the maintainer. Mirrors
/// the Settings surface chrome (Toolbar + centered column). Submit opens the
/// default mail app pre-addressed to `hello@pomvox.ai`.
struct ReportIssueView: View {
    @State private var subject = ""
    @State private var message = ""
    @State private var opened = false

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Report an Issue") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Found a bug or have a suggestion? Send it straight to the maintainer. "
                         + "Submitting opens your mail app with the message ready to send — "
                         + "nothing leaves your Mac until you press send there.")
                        .font(Typo.ui(13)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    card
                }
                .frame(maxWidth: 660, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34).padding(.top, 24).padding(.bottom, 44)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(label: "To") {
                Text(ReportIssue.recipient)
                    .font(Typo.ui(12.5)).foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
                    .accessibilityLabel("Recipient \(ReportIssue.recipient)")
            }

            field(label: "Subject") {
                TextField("", text: $subject)
                    .textFieldStyle(.plain).font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
            }

            field(label: "Message") {
                TextEditor(text: $message)
                    .font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
            }

            HStack(spacing: 12) {
                if opened {
                    Label("Opened in your mail app", systemImage: "checkmark.circle.fill")
                        .font(Typo.ui(12, .medium)).foregroundStyle(Palette.gold)
                }
                Spacer()
                Button(action: submit) {
                    Text("Submit").font(Typo.ui(13, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Capsule().fill(Palette.ember))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Submit issue report")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
    }

    private func field<Content: View>(
        label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Typo.ui(10.5, .semibold)).tracking(0.5).foregroundStyle(Palette.muted)
            content()
        }
    }

    private func submit() {
        guard let url = ReportIssue.mailtoURL(subject: subject, body: message) else { return }
        NSWorkspace.shared.open(url)
        opened = true
    }
}
