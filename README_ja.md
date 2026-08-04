# TKMY

日本語 | [English](README.md)

**TKMY（トークン見えるやつ）**は、CodexとClaude Codeのローカルなトークン利用状況を、それぞれ独立したメーターとして表示するオープンソースのmacOSメニューバーアプリです。詳細画面では、本日の入力・出力トークン数、推定金額（USD）、直近12か月の日別ヒートマップを確認できます。

どちらかのメーターを右クリックして**設定…**を選ぶと、表示言語、ログイン時の起動、マウスオーバーでの詳細表示、アップデートの自動確認、Codex／Claude Codeメニューの表示・非表示を変更できます。設定画面を開けるように、少なくとも一方のメニューは常に表示されます。

初回起動時はMacの優先言語から対応する言語を自動選択します。表示言語は、英語、日本語、ドイツ語、簡体字中国語、フランス語、韓国語、スペイン語、イタリア語、ベトナム語、タイ語、繁体字中国語の11言語から選択でき、アプリ全体へ即時反映されます。

TKMYは端末内に保存されたJSONL形式の利用記録を読み取ります。プロンプト、応答内容、ソースコード、プロジェクトパス、APIキーは保存しません。

## 開発状況

このリポジトリには、MVPとして動作するSwift Packageの実装が含まれています。表示する料金は参考用の推定値であり、実際の請求額ではありません。価格を特定できないモデルは、`$0.00`ではなく算出不可として表示します。

同梱の価格表は、公開価格を確認できるCodexのモデル系統とClaude Sonnet 4.6に対応しています。価格表には公式情報の参照URLと取得日を記録しています。公開されたAPI価格がないプレビュー版・内部モデルは、確認済みの価格が追加されるまで算出不可として扱います。

## 動作要件

- macOS 14以降
- Xcode 26、または互換性のあるSwift 6ツールチェーン

## ビルドとテスト

```sh
swift test --disable-sandbox --scratch-path .build -Xcc -fmodules-cache-path=.build/ModuleCache
./Scripts/build-app.sh
open '.build/app/TKMY.app'
```

初回ビルド時に[Sparkle 2](https://github.com/sparkle-project/Sparkle)を取得します。生成される`.app`には開発用のad-hoc署名を付けます。公式配布版ではDeveloper IDによる署名、Appleの公証、Sparkle EdDSA署名が必要です。

[CIワークフロー](https://github.com/mumei/tkmy/actions/workflows/ci.yml)は手動でも実行できます。テスト後にリリース構成の`TKMY.app`を生成し、ad-hoc署名済みZIPとSHA-256チェックサムを14日間ダウンロード可能なartifactとして保存します。

公式リリースは[Releaseワークフロー](https://github.com/mumei/tkmy/actions/workflows/release.yml)からバージョンを指定して実行します。リリース前に`changeLog/<バージョン>.md`を追加してください。11言語の内容を検証し、GitHub Release本文とSparkleの更新内容へ反映します。GitHub ActionsがアプリのDeveloper ID署名とApple公証を行い、Applicationsリンク付きDMGを作成してDMG自体も公証した後、DMG・ZIP・SHA-256チェックサム・署名付き`appcast.xml`をGitHub Releasesへ公開します。GitHubの`release` EnvironmentにはSecretsとして`CERTIFICATE_P12_BASE64`、`CERTIFICATE_PASSWORD`、`NOTARY_KEY_BASE64`、`SPARKLE_PRIVATE_KEY`、Variablesとして`TKMY_FEED_URL`、`SPARKLE_PUBLIC_KEY`の登録が必要です。公証のKey ID、Issuer ID、Developer ID名はRepository Variablesで上書きできます。

## ローカルデータの参照先

- Codex：`${CODEX_HOME:-~/.codex}/sessions`および`archived_sessions`
- Claude Code：`~/.claude/projects`、`~/.config/claude/projects`、`CLAUDE_CONFIG_DIR`

集計データベースは`~/Library/Application Support/TKMY/usage.sqlite3`に保存します。

## ドキュメント

- [要件定義](index.html)
- [技術設計](design.html)
- [コントリビューションガイド](CONTRIBUTING.md)
- [セキュリティポリシー](SECURITY.md)

## ライセンス

MIT Licenseで公開しています。依存ライブラリおよび第三者データのライセンス情報は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を参照してください。
