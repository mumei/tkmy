/* Hallmark · component: settings window · genre: technical-utilitarian · theme: macOS-native
 * states: native default · hover · focus · active · disabled · progress · error · success
 * Hallmark · pre-emit critique: P5 H5 E4 S5 R5 V4
 */
import SwiftUI
import UpdateSupport
import UsageDomain

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let updateController: UpdateController

    @State private var automaticallyChecksForUpdates: Bool

    init(settings: AppSettings, updateController: UpdateController) {
        self.settings = settings
        self.updateController = updateController
        _automaticallyChecksForUpdates = State(
            initialValue: updateController.automaticallyChecksForUpdates
        )
    }

    var body: some View {
        Form {
            Section(L10n.text("general")) {
                Picker(L10n.text("display_language"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Text(L10n.text("language_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.text("launch_at_login"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Toggle(L10n.text("open_details_on_hover"), isOn: $settings.opensDetailsOnHover)

                if let error = settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(L10n.text("launch_error", error))
                }
            }

            Section(L10n.text("menubar")) {
                Toggle(L10n.text("show_codex"), isOn: menuVisibilityBinding(for: .codex))
                Toggle(L10n.text("show_claude"), isOn: menuVisibilityBinding(for: .claudeCode))

                Picker(L10n.text("meter_style"), selection: $settings.menuMeterStyle) {
                    ForEach(MenuMeterStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Toggle(L10n.text("show_label"), isOn: $settings.showsMenuLabel)
                Toggle(L10n.text("show_remaining_percentage"), isOn: $settings.showsRemainingPercentage)

                Picker(L10n.text("content_order"), selection: $settings.meterContentOrder) {
                    ForEach(AppSettings.MeterContentOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.menuMeterStyle == .percentageOnly)

                LabeledContent(L10n.text("preview")) {
                    HStack(spacing: 6) {
                        if settings.meterContentOrder == .graphLeading {
                            previewGraph
                        }
                        if !previewLabel.isEmpty {
                            Text(previewLabel).monospacedDigit()
                        }
                        if settings.meterContentOrder == .graphTrailing {
                            previewGraph
                        }
                    }
                }

                if let error = settings.menuVisibilityError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(L10n.text("menu_visibility_a11y_error", error))
                } else {
                    Text(L10n.text("at_least_one_menu"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("updates")) {
                Toggle(L10n.text("automatic_updates"), isOn: $automaticallyChecksForUpdates)
                    .disabled(!updateController.isConfigured)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        updateController.automaticallyChecksForUpdates = newValue
                    }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateController.isConfigured ? L10n.text("sparkle_updates") : L10n.text("updates_not_configured"))
                        Text(updateController.isConfigured ? L10n.text("update_notification") : L10n.text("updates_available_after_config"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("check_now")) {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.isConfigured)
                }
            }

            Section(L10n.text("information")) {
                LabeledContent(L10n.text("version"), value: versionText)
                LabeledContent(L10n.text("license"), value: "MIT License")
                LabeledContent(L10n.text("creator")) {
                    Link("@yuto_uehara_san", destination: Self.creatorURL)
                        .accessibilityHint(L10n.text("creator_link_hint"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .environment(\.locale, Locale(identifier: settings.appLanguage.rawValue))
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            automaticallyChecksForUpdates = updateController.automaticallyChecksForUpdates
        }
    }

    private var previewLabel: String {
        let source = settings.showsMenuLabel ? "Codex" : ""
        let percentage = settings.showsRemainingPercentage ? L10n.text("remaining_format", "58%") : ""
        let label = [source, percentage].filter { !$0.isEmpty }.joined(separator: " ")
        if label.isEmpty, settings.menuMeterStyle == .percentageOnly {
            return "Codex"
        }
        return label
    }

    @ViewBuilder
    private var previewGraph: some View {
        if let image = MenuMeterRenderer.image(
            style: settings.menuMeterStyle,
            percentage: 58,
            source: .codex
        ) {
            Image(nsImage: image)
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private static let creatorURL = URL(string: "https://x.com/yuto_uehara_san")!

    private func menuVisibilityBinding(for source: UsageSource) -> Binding<Bool> {
        Binding(
            get: { settings.isMenuVisible(for: source) },
            set: { settings.setMenuVisible($0, for: source) }
        )
    }
}
