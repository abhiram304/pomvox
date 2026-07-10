import Foundation

/// Builds the `mailto:` link the "Report an issue" button (General settings)
/// hands to the user's mail client. Pomvox has no account and sends nothing
/// itself — clicking opens the default mail app pre-addressed to the maintainer,
/// and the user presses send there (so their own return address is used, and no
/// SMTP credentials live in the app).
///
/// Pure logic (fields → URL) so the encoding is unit-tested; opening the URL is
/// the thin shell at the call site.
enum ReportIssue {
    static let recipient = "hello@pomvox.ai"

    /// A `mailto:` URL for the given fields. Subject/body are optional — an empty
    /// value is omitted from the query so the composer opens blank there.
    static func mailtoURL(to: String = recipient, subject: String = "", body: String = "") -> URL? {
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
