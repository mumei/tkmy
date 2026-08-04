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
            Section("一般") {
                Toggle("ログイン時にTKMYを起動", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Toggle("ポインタを置いたときに詳細を開く", isOn: $settings.opensDetailsOnHover)

                if let error = settings.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("ログイン時の起動設定エラー: \(error)")
                }
            }

            Section("メニューバー") {
                Toggle("Codexを表示", isOn: menuVisibilityBinding(for: .codex))
                Toggle("Claude Codeを表示", isOn: menuVisibilityBinding(for: .claudeCode))

                Picker("メーターの表示", selection: $settings.menuMeterStyle) {
                    ForEach(MenuMeterStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Toggle("ラベルを表示", isOn: $settings.showsMenuLabel)
                Toggle("残量パーセントを表示", isOn: $settings.showsRemainingPercentage)

                Picker("ラベルとグラフの並び", selection: $settings.meterContentOrder) {
                    ForEach(AppSettings.MeterContentOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.menuMeterStyle == .percentageOnly)

                LabeledContent("プレビュー") {
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
                        .accessibilityLabel("メニューバー表示設定エラー: \(error)")
                } else {
                    Text("設定を開くため、少なくとも片方のメニューを表示します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("アップデート") {
                Toggle("アップデートを自動的に確認", isOn: $automaticallyChecksForUpdates)
                    .disabled(!updateController.isConfigured)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        updateController.automaticallyChecksForUpdates = newValue
                    }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateController.isConfigured ? "Sparkleから更新を取得します" : "開発ビルドでは更新先が未設定です")
                        Text(updateController.isConfigured ? "新しいバージョンがある場合に通知します。" : "正式な配布設定を行うと利用できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("今すぐ確認") {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.isConfigured)
                }
            }

            Section("情報") {
                LabeledContent("バージョン", value: versionText)
                LabeledContent("ライセンス", value: "MIT License")
                LabeledContent("制作者") {
                    Link("@yuto_uehara_san", destination: Self.creatorURL)
                        .accessibilityHint("Xの制作者プロフィールを開きます")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            automaticallyChecksForUpdates = updateController.automaticallyChecksForUpdates
        }
    }

    private var previewLabel: String {
        let source = settings.showsMenuLabel ? "Codex" : ""
        let percentage = settings.showsRemainingPercentage ? "残り58%" : ""
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
