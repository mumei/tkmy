import SwiftUI
import UsageDomain

struct ThirdPartyLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("open_source_licenses"))
                    .font(.title2.bold())
                Spacer()
                Button(L10n.text("close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sparkle")
                        .font(.headline)
                    Text("MIT License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("github.com/sparkle-project/Sparkle", destination: Self.sparkleURL)
            }

            ScrollView {
                Text(licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return L10n.text("license_unavailable")
        }
        return text
    }

    private static let sparkleURL = URL(string: "https://github.com/sparkle-project/Sparkle")!
}
