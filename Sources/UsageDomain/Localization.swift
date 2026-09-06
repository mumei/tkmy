import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"
    case german = "de"
    case simplifiedChinese = "zh-Hans"
    case french = "fr"
    case korean = "ko"
    case spanish = "es"
    case italian = "it"
    case vietnamese = "vi"
    case thai = "th"
    case traditionalChinese = "zh-Hant"

    public var id: String { rawValue }

    public var nativeName: String {
        switch self {
        case .english: "English"
        case .japanese: "日本語"
        case .german: "Deutsch"
        case .simplifiedChinese: "简体中文"
        case .french: "Français"
        case .korean: "한국어"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .vietnamese: "Tiếng Việt"
        case .thai: "ไทย"
        case .traditionalChinese: "繁體中文"
        }
    }

    public static func systemDefault(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized.hasPrefix("zh-hant")
                || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk")
                || normalized.hasPrefix("zh-mo") {
                return .traditionalChinese
            }
            if normalized.hasPrefix("zh-hans")
                || normalized.hasPrefix("zh-cn")
                || normalized.hasPrefix("zh-sg")
                || normalized == "zh" {
                return .simplifiedChinese
            }
            if let language = Self.allCases.first(where: {
                normalized == $0.rawValue.lowercased()
                    || normalized.hasPrefix($0.rawValue.lowercased() + "-")
            }) {
                return language
            }
        }
        return .english
    }

    fileprivate var translationIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 1
    }
}

public enum L10n {
    public static let defaultsKey = "appLanguage"

    public static var language: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey)
        return AppLanguage(rawValue: rawValue ?? "") ?? .systemDefault()
    }

    public static var locale: Locale {
        Locale(identifier: language.rawValue)
    }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        text(key, language: language, arguments: arguments)
    }

    public static func text(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        text(key, language: language, arguments: arguments)
    }

    private static func text(
        _ key: String,
        language: AppLanguage,
        arguments: [CVarArg]
    ) -> String {
        let values = translations[key]
        let format: String
        if language == .traditionalChinese,
           let simplified = values?[safe: AppLanguage.simplifiedChinese.translationIndex] {
            format = traditionalChineseOverrides[key]
                ?? simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
                ?? simplified
        } else {
            format = values?[safe: language.translationIndex]
                ?? values?[safe: AppLanguage.english.translationIndex]
                ?? key
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    // Order: English, Japanese, German, Simplified Chinese, French,
    // Korean, Spanish, Italian, Vietnamese, Thai. Traditional Chinese is
    // derived from Simplified Chinese to match the Capswitch language model.
    private static let traditionalChineseOverrides: [String: String] = [
        "settings_title": "TKMY 設定",
        "settings": "設定…",
        "at_least_one_menu": "請至少保留一個選單，以便開啟設定。",
        "menu_visibility_error": "請至少顯示一個選單，以便開啟設定。",
        "menu_visibility_a11y_error": "選單列顯示設定錯誤：%@",
    ]

    private static let translations: [String: [String]] = [
        "general": ["General", "一般", "Allgemein", "通用", "Général", "일반", "General", "Generali", "Chung", "ทั่วไป"],
        "language": ["Language", "言語", "Sprache", "语言", "Langue", "언어", "Idioma", "Lingua", "Ngôn ngữ", "ภาษา"],
        "display_language": ["Display language", "表示言語", "Anzeigesprache", "显示语言", "Langue d’affichage", "표시 언어", "Idioma de visualización", "Lingua di visualizzazione", "Ngôn ngữ hiển thị", "ภาษาที่แสดง"],
        "language_hint": ["Changes are applied immediately throughout the app.", "変更はアプリ全体へすぐに反映されます。", "Änderungen werden sofort in der gesamten App übernommen.", "更改会立即应用到整个应用。", "Les modifications s’appliquent immédiatement dans toute l’app.", "변경 사항은 앱 전체에 즉시 적용됩니다.", "Los cambios se aplican al instante en toda la app.", "Le modifiche vengono applicate subito in tutta l’app.", "Thay đổi được áp dụng ngay trong toàn bộ ứng dụng.", "การเปลี่ยนแปลงจะมีผลทันทีทั่วทั้งแอป"],
        "launch_at_login": ["Launch TKMY at login", "ログイン時にTKMYを起動", "TKMY bei Anmeldung starten", "登录时启动 TKMY", "Lancer TKMY à l’ouverture de session", "로그인할 때 TKMY 시작", "Abrir TKMY al iniciar sesión", "Avvia TKMY al login", "Khởi động TKMY khi đăng nhập", "เปิด TKMY เมื่อเข้าสู่ระบบ"],
        "open_details_on_hover": ["Open details when the pointer hovers", "ポインタを置いたときに詳細を開く", "Details beim Darüberfahren öffnen", "指针悬停时打开详情", "Ouvrir les détails au survol", "포인터를 올리면 세부 정보 열기", "Abrir detalles al pasar el puntero", "Apri i dettagli al passaggio del puntatore", "Mở chi tiết khi di chuột", "เปิดรายละเอียดเมื่อวางตัวชี้"],
        "launch_error": ["Login launch setting error: %@", "ログイン時の起動設定エラー: %@", "Fehler bei der Anmelde-Startoption: %@", "登录启动设置错误：%@", "Erreur du lancement à l’ouverture de session : %@", "로그인 시 시작 설정 오류: %@", "Error de inicio de sesión: %@", "Errore avvio al login: %@", "Lỗi cài đặt khởi động khi đăng nhập: %@", "ข้อผิดพลาดการตั้งค่าเริ่มเมื่อเข้าสู่ระบบ: %@"],
        "menubar": ["Menu Bar", "メニューバー", "Menüleiste", "菜单栏", "Barre des menus", "메뉴 막대", "Barra de menús", "Barra dei menu", "Thanh menu", "แถบเมนู"],
        "show_codex": ["Show Codex", "Codexを表示", "Codex anzeigen", "显示 Codex", "Afficher Codex", "Codex 표시", "Mostrar Codex", "Mostra Codex", "Hiển thị Codex", "แสดง Codex"],
        "show_claude": ["Show Claude Code", "Claude Codeを表示", "Claude Code anzeigen", "显示 Claude Code", "Afficher Claude Code", "Claude Code 표시", "Mostrar Claude Code", "Mostra Claude Code", "Hiển thị Claude Code", "แสดง Claude Code"],
        "meter_style": ["Meter style", "メーターの表示", "Meter-Stil", "仪表样式", "Style du compteur", "미터 스타일", "Estilo del medidor", "Stile indicatore", "Kiểu đồng hồ", "รูปแบบมิเตอร์"],
        "show_label": ["Show label", "ラベルを表示", "Beschriftung anzeigen", "显示标签", "Afficher le libellé", "레이블 표시", "Mostrar etiqueta", "Mostra etichetta", "Hiển thị nhãn", "แสดงป้ายกำกับ"],
        "show_remaining_percentage": ["Show remaining percentage", "残量パーセントを表示", "Verbleibenden Prozentsatz anzeigen", "显示剩余百分比", "Afficher le pourcentage restant", "남은 비율 표시", "Mostrar porcentaje restante", "Mostra percentuale rimanente", "Hiển thị phần trăm còn lại", "แสดงเปอร์เซ็นต์ที่เหลือ"],
        "content_order": ["Label and graph order", "ラベルとグラフの並び", "Reihenfolge von Text und Grafik", "标签和图表顺序", "Ordre du libellé et du graphique", "레이블 및 그래프 순서", "Orden de etiqueta y gráfico", "Ordine etichetta e grafico", "Thứ tự nhãn và biểu đồ", "ลำดับป้ายกำกับและกราฟ"],
        "preview": ["Preview", "プレビュー", "Vorschau", "预览", "Aperçu", "미리보기", "Vista previa", "Anteprima", "Xem trước", "ตัวอย่าง"],
        "at_least_one_menu": ["Keep at least one menu visible so Settings remains accessible.", "設定を開くため、少なくとも片方のメニューを表示します。", "Mindestens ein Menü muss sichtbar bleiben, damit die Einstellungen erreichbar sind.", "请至少保留一个菜单，以便打开设置。", "Gardez au moins un menu visible pour accéder aux réglages.", "설정을 열 수 있도록 메뉴를 하나 이상 표시하세요.", "Mantén al menos un menú visible para acceder a Ajustes.", "Mantieni visibile almeno un menu per accedere alle impostazioni.", "Giữ ít nhất một menu hiển thị để mở Cài đặt.", "แสดงเมนูอย่างน้อยหนึ่งรายการเพื่อให้เปิดการตั้งค่าได้"],
        "menu_visibility_error": ["Keep at least one menu visible so Settings can be opened.", "設定を開けるように、少なくとも片方を表示してください。", "Mindestens ein Menü muss sichtbar bleiben, damit die Einstellungen geöffnet werden können.", "请至少显示一个菜单，以便打开设置。", "Gardez au moins un menu visible pour ouvrir les réglages.", "설정을 열 수 있도록 메뉴를 하나 이상 표시하세요.", "Mantén al menos un menú visible para abrir Ajustes.", "Mantieni visibile almeno un menu per aprire le impostazioni.", "Giữ ít nhất một menu hiển thị để mở Cài đặt.", "แสดงเมนูอย่างน้อยหนึ่งรายการเพื่อให้เปิดการตั้งค่าได้"],
        "menu_visibility_a11y_error": ["Menu bar visibility setting error: %@", "メニューバー表示設定エラー: %@", "Fehler bei der Menüleistenanzeige: %@", "菜单栏显示设置错误：%@", "Erreur d’affichage de la barre des menus : %@", "메뉴 막대 표시 설정 오류: %@", "Error de visibilidad de la barra de menús: %@", "Errore visibilità barra dei menu: %@", "Lỗi cài đặt hiển thị thanh menu: %@", "ข้อผิดพลาดการตั้งค่าการแสดงแถบเมนู: %@"],
        "updates": ["Updates", "アップデート", "Updates", "更新", "Mises à jour", "업데이트", "Actualizaciones", "Aggiornamenti", "Cập nhật", "อัปเดต"],
        "automatic_updates": ["Automatically check for updates", "アップデートを自動的に確認", "Automatisch nach Updates suchen", "自动检查更新", "Rechercher automatiquement les mises à jour", "업데이트 자동 확인", "Buscar actualizaciones automáticamente", "Controlla automaticamente gli aggiornamenti", "Tự động kiểm tra cập nhật", "ตรวจสอบอัปเดตอัตโนมัติ"],
        "update_check": ["Check for available updates", "アップデートを確認します", "Nach verfügbaren Updates suchen", "检查可用更新", "Rechercher les mises à jour disponibles", "사용 가능한 업데이트를 확인합니다", "Comprobar si hay actualizaciones disponibles", "Controlla gli aggiornamenti disponibili", "Kiểm tra bản cập nhật hiện có", "ตรวจสอบอัปเดตที่พร้อมใช้งาน"],
        "updates_not_configured": ["The update source is not configured in development builds", "開発ビルドでは更新先が未設定です", "In Entwicklungs-Builds ist keine Update-Quelle konfiguriert", "开发版本未配置更新源", "La source de mise à jour n’est pas configurée dans les versions de développement", "개발 빌드에는 업데이트 소스가 설정되지 않았습니다", "La fuente de actualizaciones no está configurada en versiones de desarrollo", "La fonte degli aggiornamenti non è configurata nelle build di sviluppo", "Nguồn cập nhật chưa được cấu hình trong bản phát triển", "ยังไม่ได้ตั้งค่าแหล่งอัปเดตในรุ่นพัฒนา"],
        "update_notification": ["You will be notified when a new version is available.", "新しいバージョンがある場合に通知します。", "Sie werden benachrichtigt, wenn eine neue Version verfügbar ist.", "有新版本时会通知您。", "Vous serez averti lorsqu’une nouvelle version sera disponible.", "새 버전이 있으면 알려드립니다.", "Recibirás una notificación cuando haya una nueva versión.", "Riceverai una notifica quando è disponibile una nuova versione.", "Bạn sẽ được thông báo khi có phiên bản mới.", "จะแจ้งให้ทราบเมื่อมีเวอร์ชันใหม่"],
        "updates_available_after_config": ["Available after configuring an official distribution.", "正式な配布設定を行うと利用できます。", "Nach Konfiguration der offiziellen Verteilung verfügbar.", "配置正式分发后可用。", "Disponible après configuration d’une distribution officielle.", "공식 배포 설정 후 사용할 수 있습니다.", "Disponible tras configurar una distribución oficial.", "Disponibile dopo aver configurato una distribuzione ufficiale.", "Khả dụng sau khi cấu hình bản phân phối chính thức.", "ใช้งานได้หลังตั้งค่าการเผยแพร่อย่างเป็นทางการ"],
        "check_now": ["Check Now", "今すぐ確認", "Jetzt suchen", "立即检查", "Rechercher maintenant", "지금 확인", "Comprobar ahora", "Controlla ora", "Kiểm tra ngay", "ตรวจสอบตอนนี้"],
        "information": ["Information", "情報", "Information", "信息", "Informations", "정보", "Información", "Informazioni", "Thông tin", "ข้อมูล"],
        "version": ["Version", "バージョン", "Version", "版本", "Version", "버전", "Versión", "Versione", "Phiên bản", "เวอร์ชัน"],
        "license": ["License", "ライセンス", "Lizenz", "许可证", "Licence", "라이선스", "Licencia", "Licenza", "Giấy phép", "สิทธิ์การใช้งาน"],
        "open_source_licenses": ["Open Source Licenses", "オープンソースライセンス", "Open-Source-Lizenzen", "开源许可证", "Licences open source", "오픈 소스 라이선스", "Licencias de código abierto", "Licenze open source", "Giấy phép mã nguồn mở", "สัญญาอนุญาตโอเพนซอร์ส"],
        "show": ["Show…", "表示…", "Anzeigen…", "显示…", "Afficher…", "보기…", "Mostrar…", "Mostra…", "Hiển thị…", "แสดง…"],
        "close": ["Close", "閉じる", "Schließen", "关闭", "Fermer", "닫기", "Cerrar", "Chiudi", "Đóng", "ปิด"],
        "license_unavailable": ["The license text could not be loaded.", "ライセンス本文を読み込めませんでした。", "Der Lizenztext konnte nicht geladen werden.", "无法加载许可证文本。", "Le texte de la licence n’a pas pu être chargé.", "라이선스 전문을 불러올 수 없습니다.", "No se pudo cargar el texto de la licencia.", "Impossibile caricare il testo della licenza.", "Không thể tải nội dung giấy phép.", "ไม่สามารถโหลดข้อความสัญญาอนุญาตได้"],
        "creator": ["Creator", "制作者", "Erstellt von", "制作者", "Créateur", "제작자", "Creador", "Autore", "Tác giả", "ผู้สร้าง"],
        "creator_link_hint": ["Open the creator’s profile on X", "Xの制作者プロフィールを開きます", "Profil des Erstellers auf X öffnen", "在 X 上打开制作者的个人资料", "Ouvrir le profil du créateur sur X", "X에서 제작자 프로필 열기", "Abrir el perfil del creador en X", "Apri il profilo dell’autore su X", "Mở hồ sơ tác giả trên X", "เปิดโปรไฟล์ผู้สร้างบน X"],
        "settings_title": ["TKMY Settings", "TKMY 設定", "TKMY-Einstellungen", "TKMY 设置", "Réglages TKMY", "TKMY 설정", "Ajustes de TKMY", "Impostazioni TKMY", "Cài đặt TKMY", "การตั้งค่า TKMY"],
        "graph_leading": ["Graph first", "グラフを左に表示", "Grafik zuerst", "图表在前", "Graphique en premier", "그래프 먼저", "Gráfico primero", "Grafico prima", "Biểu đồ trước", "กราฟก่อน"],
        "graph_trailing": ["Label first", "グラフを右に表示", "Text zuerst", "标签在前", "Libellé en premier", "레이블 먼저", "Etiqueta primero", "Etichetta prima", "Nhãn trước", "ป้ายกำกับก่อน"],
        "style_colored_bar": ["Color bar", "カラーバー", "Farbbalken", "彩色条", "Barre colorée", "컬러 막대", "Barra de color", "Barra colorata", "Thanh màu", "แถบสี"],
        "style_monochrome_bar": ["Monochrome bar", "モノクロバー", "Monochromer Balken", "单色条", "Barre monochrome", "단색 막대", "Barra monocroma", "Barra monocromatica", "Thanh đơn sắc", "แถบสีเดียว"],
        "style_segments": ["Segments", "分割", "Segmente", "分段", "Segments", "분할", "Segmentos", "Segmenti", "Phân đoạn", "แบ่งส่วน"],
        "style_colored_segments": ["Color segments", "カラー分割", "Farbsegmente", "彩色分段", "Segments colorés", "컬러 분할", "Segmentos de color", "Segmenti colorati", "Phân đoạn màu", "แบ่งส่วนสี"],
        "style_dots": ["Dots", "ドット", "Punkte", "圆点", "Points", "점", "Puntos", "Punti", "Chấm", "จุด"],
        "style_ring": ["Ring", "リング", "Ring", "圆环", "Anneau", "링", "Anillo", "Anello", "Vòng", "วงแหวน"],
        "style_gauge": ["Gauge", "ゲージ", "Anzeige", "仪表", "Jauge", "게이지", "Indicador", "Indicatore", "Đồng hồ", "มาตรวัด"],
        "style_battery": ["Battery", "バッテリー", "Batterie", "电池", "Batterie", "배터리", "Batería", "Batteria", "Pin", "แบตเตอรี่"],
        "style_vertical_bars": ["Vertical bars", "縦バー", "Vertikale Balken", "竖条", "Barres verticales", "세로 막대", "Barras verticales", "Barre verticali", "Thanh dọc", "แถบแนวตั้ง"],
        "style_percentage_only": ["Number only", "数字のみ", "Nur Zahl", "仅数字", "Nombre uniquement", "숫자만", "Solo número", "Solo numero", "Chỉ số", "ตัวเลขเท่านั้น"],
        "remaining_format": ["%@ left", "残り%@", "%@ übrig", "剩余 %@", "%@ restants", "%@ 남음", "Queda %@", "%@ rimasto", "Còn %@", "เหลือ %@"],
        "usage_pane": ["Usage view", "利用状況ビュー", "Nutzungsansicht", "用量视图", "Vue d’utilisation", "사용량 보기", "Vista de uso", "Vista utilizzo", "Chế độ xem sử dụng", "มุมมองการใช้งาน"],
        "token_usage_pane": ["Token usage", "トークン利用", "Token-Nutzung", "令牌使用", "Utilisation des jetons", "토큰 사용량", "Uso de tokens", "Utilizzo token", "Mức dùng token", "การใช้โทเค็น"],
        "quota_history_pane": ["Quota history", "残量履歴", "Kontingentverlauf", "额度历史", "Historique de quota", "할당량 기록", "Historial de cuota", "Cronologia quota", "Lịch sử hạn mức", "ประวัติโควต้า"],
        "remaining_quota_history": ["Remaining quota history", "残量履歴", "Verlauf des Restkontingents", "剩余额度历史", "Historique du quota restant", "남은 할당량 기록", "Historial de cuota restante", "Cronologia quota residua", "Lịch sử hạn mức còn lại", "ประวัติโควต้าคงเหลือ"],
        "quota_period": ["Period", "期間", "Zeitraum", "时间范围", "Période", "기간", "Período", "Periodo", "Khoảng thời gian", "ช่วงเวลา"],
        "quota_range_7d": ["7 days", "7日", "7 Tage", "7天", "7 jours", "7일", "7 días", "7 giorni", "7 ngày", "7 วัน"],
        "quota_range_30d": ["30 days", "30日", "30 Tage", "30天", "30 jours", "30일", "30 días", "30 giorni", "30 ngày", "30 วัน"],
        "quota_range_1h": ["1 hour", "1時間", "1 Stunde", "1小时", "1 heure", "1시간", "1 hora", "1 ora", "1 giờ", "1 ชั่วโมง"],
        "quota_range_6h": ["6 hours", "6時間", "6 Stunden", "6小时", "6 heures", "6시간", "6 horas", "6 ore", "6 giờ", "6 ชั่วโมง"],
        "quota_range_12h": ["12 hours", "12時間", "12 Stunden", "12小时", "12 heures", "12시간", "12 horas", "12 ore", "12 giờ", "12 ชั่วโมง"],
        "quota_range_1d": ["1 day", "1日", "1 Tag", "1天", "1 jour", "1일", "1 día", "1 giorno", "1 ngày", "1 วัน"],
        "quota_window": ["Quota window", "利用枠", "Kontingentfenster", "额度窗口", "Fenêtre de quota", "할당량 기간", "Ventana de cuota", "Finestra quota", "Khung hạn mức", "ช่วงโควต้า"],
        "quota_general": ["General", "全般", "Allgemein", "通用", "Général", "일반", "General", "Generale", "Chung", "ทั่วไป"],
        "quota_model_limit": ["Model: %@", "モデル: %@", "Modell: %@", "模型：%@", "Modèle : %@", "모델: %@", "Modelo: %@", "Modello: %@", "Mô hình: %@", "โมเดล: %@"],
        "quota_window_format": ["%@ · %@", "%@・%@", "%@ · %@", "%@ · %@", "%@ · %@", "%@ · %@", "%@ · %@", "%@ · %@", "%@ · %@", "%@ · %@"],
        "quota_history_empty_title": ["No quota history yet", "残量履歴はまだありません", "Noch kein Kontingentverlauf", "暂无额度历史", "Aucun historique de quota", "할당량 기록이 아직 없습니다", "Aún no hay historial de cuota", "Nessuna cronologia quota", "Chưa có lịch sử hạn mức", "ยังไม่มีประวัติโควต้า"],
        "quota_history_empty_message": ["Quota observations appear here after Codex reports them.", "Codexが利用枠を報告すると、ここに履歴が表示されます。", "Hier erscheinen Kontingentwerte, sobald Codex sie meldet.", "Codex 报告额度后，观测记录会显示在这里。", "Les relevés apparaîtront ici dès que Codex les signalera.", "Codex가 할당량을 보고하면 여기에 기록이 표시됩니다.", "Las observaciones aparecerán aquí cuando Codex las informe.", "Le osservazioni appariranno qui quando Codex le segnala.", "Các lần ghi nhận sẽ hiện ở đây sau khi Codex báo cáo.", "รายการจะปรากฏที่นี่เมื่อ Codex รายงานโควต้า"],
        "quota_history_period_empty": ["No observations fall within this period.", "この期間の観測はありません。", "In diesem Zeitraum gibt es keine Beobachtungen.", "此时间范围内没有观测记录。", "Aucun relevé pour cette période.", "이 기간에는 기록이 없습니다.", "No hay observaciones en este período.", "Nessuna osservazione in questo periodo.", "Không có lần ghi nhận trong khoảng này.", "ไม่มีรายการในช่วงเวลานี้"],
        "quota_observed": ["Observed", "観測時刻", "Beobachtet", "观测时间", "Relevé", "관측 시각", "Observado", "Osservato", "Thời điểm ghi nhận", "เวลาที่บันทึก"],
        "quota_confirmation_period": ["Confirmation period", "確認期間", "Bestätigungszeitraum", "确认时段", "Période de confirmation", "확인 기간", "Período de confirmación", "Periodo di conferma", "Khoảng xác nhận", "ช่วงเวลายืนยัน"],
        "quota_last_confirmed": ["Last confirmed %@", "最終確認 %@", "Zuletzt bestätigt %@", "最后确认 %@", "Dernière confirmation %@", "마지막 확인 %@", "Última confirmación %@", "Ultima conferma %@", "Xác nhận lần cuối %@", "ยืนยันล่าสุด %@"],
        "quota_single_observation": ["Single observation", "1時点の確認", "Einzelne Beobachtung", "单次观测", "Observation unique", "단일 관측", "Observación única", "Singola osservazione", "Một lần ghi nhận", "การสังเกตหนึ่งครั้ง"],
        "quota_less_than_minute": ["Less than 1 minute", "1分未満", "Weniger als 1 Minute", "不足 1 分钟", "Moins d’une minute", "1분 미만", "Menos de 1 minuto", "Meno di 1 minuto", "Dưới 1 phút", "น้อยกว่า 1 นาที"],
        "quota_consumption_pace": ["Consumption pace", "消費ペース", "Verbrauchstempo", "消耗速度", "Rythme de consommation", "소비 속도", "Ritmo de consumo", "Ritmo di consumo", "Tốc độ tiêu thụ", "อัตราการใช้"],
        "quota_pace_recent": ["Latest continuous observations", "直近の連続した観測", "Neueste zusammenhängende Beobachtungen", "最近的连续观测", "Dernières observations continues", "최근 연속 관측", "Observaciones continuas más recientes", "Osservazioni continue più recenti", "Các lần ghi nhận liên tục gần đây", "การสังเกตต่อเนื่องล่าสุด"],
        "quota_pace_average_format": ["Average: about %@ per 1%%", "平均1%%あたり約%@", "Durchschnitt: etwa %@ pro 1 %%", "平均每 1%% 约 %@", "Moyenne : environ %@ par 1 %%", "평균 1%%당 약 %@", "Promedio: aproximadamente %@ por 1 %%", "Media: circa %@ per 1%%", "Trung bình: khoảng %@ cho mỗi 1%%", "เฉลี่ยประมาณ %@ ต่อ 1%%"],
        "quota_pace_basis_format": ["%@ elapsed, %@ percentage-point drop", "%@で%@ポイント減少", "%@ vergangen, %@ Prozentpunkte gesunken", "经过 %@，下降 %@ 个百分点", "%@ écoulées, baisse de %@ points", "%@ 경과, %@포인트 감소", "%@ transcurridos, descenso de %@ puntos porcentuales", "%@ trascorsi, calo di %@ punti percentuali", "Đã qua %@, giảm %@ điểm phần trăm", "ผ่านไป %@ ลดลง %@ จุดเปอร์เซ็นต์"],
        "quota_pace_note": ["Account-wide observed estimate, not active work time.", "アカウント全体の観測上の目安です。実作業時間ではありません。", "Kontoweite Beobachtungsschätzung, keine aktive Arbeitszeit.", "基于整个账户观测的估计，并非实际工作时间。", "Estimation observée pour l’ensemble du compte, pas du temps de travail actif.", "계정 전체 관측에 따른 추정치이며 실제 작업 시간은 아닙니다.", "Estimación observada para toda la cuenta; no es tiempo de trabajo activo.", "Stima osservata dell’intero account, non tempo di lavoro attivo.", "Ước tính quan sát trên toàn tài khoản, không phải thời gian làm việc thực tế.", "ค่าประมาณจากการสังเกตทั้งบัญชี ไม่ใช่เวลาทำงานจริง"],
        "quota_pace_insufficient": ["Not enough observations to estimate this period’s pace", "この期間では消費ペースを算出できません", "Nicht genügend Beobachtungen für eine Schätzung in diesem Zeitraum", "此期间观测不足，无法估算消耗速度", "Pas assez de relevés pour estimer le rythme de cette période", "이 기간의 소비 속도를 추정할 관측이 충분하지 않습니다", "No hay suficientes observaciones para estimar el ritmo de este período", "Osservazioni insufficienti per stimare il ritmo di questo periodo", "Không đủ lần ghi nhận để ước tính tốc độ trong khoảng này", "มีข้อมูลสังเกตไม่เพียงพอที่จะประเมินอัตราในช่วงนี้"],
        "quota_tokens_average_format": ["Average: about %@ tokens per 1%%", "平均1%%あたり約%@トークン", "Durchschnitt: etwa %@ Token pro 1 %%", "平均每 1%% 约 %@ 个令牌", "Moyenne : environ %@ jetons par 1 %%", "평균 1%%당 약 %@토큰", "Promedio: aproximadamente %@ tokens por 1 %%", "Media: circa %@ token per 1%%", "Trung bình: khoảng %@ token cho mỗi 1%%", "เฉลี่ยประมาณ %@ โทเค็นต่อ 1%%"],
        "quota_tokens_breakdown_format": ["Input %@ · Cached input %@ · Output %@", "入力 %@ · キャッシュ入力 %@ · 出力 %@", "Eingabe %@ · Zwischengespeicherte Eingabe %@ · Ausgabe %@", "输入 %@ · 缓存输入 %@ · 输出 %@", "Entrée %@ · Entrée en cache %@ · Sortie %@", "입력 %@ · 캐시 입력 %@ · 출력 %@", "Entrada %@ · Entrada en caché %@ · Salida %@", "Input %@ · Input memorizzato %@ · Output %@", "Đầu vào %@ · Đầu vào đã lưu đệm %@ · Đầu ra %@", "อินพุต %@ · อินพุตแคช %@ · เอาต์พุต %@"],
        "quota_tokens_note": ["Compared with Codex logs on this Mac. Unrecorded voice and other-device usage are excluded; this is not a fixed conversion.", "このMacのCodex記録との比較です。音声・他端末などの未計測分は含まず、固定換算ではありません。", "Verglichen mit Codex-Protokollen auf diesem Mac. Nicht erfasste Sprach- und Gerätenutzung ist ausgeschlossen; dies ist keine feste Umrechnung.", "与此 Mac 上的 Codex 日志比较。未记录的语音和其他设备使用量不包括在内；这不是固定换算。", "Comparé aux journaux Codex de ce Mac. La voix non enregistrée et l’utilisation sur d’autres appareils sont exclues ; ce n’est pas une conversion fixe.", "이 Mac의 Codex 로그와 비교한 값입니다. 기록되지 않은 음성 및 다른 기기 사용량은 제외되며, 고정 환산이 아닙니다.", "Comparado con los registros de Codex de esta Mac. Se excluyen la voz no registrada y el uso en otros dispositivos; no es una conversión fija.", "Confrontato con i log Codex su questo Mac. Sono esclusi voce non registrata e uso su altri dispositivi; non è una conversione fissa.", "So sánh với nhật ký Codex trên máy Mac này. Không gồm giọng nói chưa ghi nhận và việc dùng trên thiết bị khác; đây không phải quy đổi cố định.", "เปรียบเทียบกับบันทึก Codex บน Mac เครื่องนี้ ไม่รวมเสียงและการใช้งานอุปกรณ์อื่นที่ไม่ได้บันทึก จึงไม่ใช่การแปลงแบบคงที่"],
        "quota_tokens_unavailable": ["Token estimate unavailable for this interval", "この区間のトークン換算は算出できません", "Tokenschätzung für dieses Intervall nicht verfügbar", "无法估算此区间的令牌数", "Estimation de jetons indisponible pour cet intervalle", "이 구간의 토큰 추정치를 계산할 수 없습니다", "La estimación de tokens no está disponible para este intervalo", "Stima dei token non disponibile per questo intervallo", "Không thể ước tính token cho khoảng này", "ไม่สามารถประเมินโทเค็นสำหรับช่วงเวลานี้ได้"],
        "quota_remaining": ["Remaining", "残量", "Verbleibend", "剩余", "Restant", "남음", "Restante", "Rimanente", "Còn lại", "คงเหลือ"],
        "quota_next_reset": ["Next reset", "次回リセット", "Nächster Reset", "下次重置", "Prochaine réinitialisation", "다음 재설정", "Próximo reinicio", "Prossimo ripristino", "Lần đặt lại tiếp theo", "รีเซ็ตครั้งถัดไป"],
        "quota_reset_unknown": ["Not reported", "未報告", "Nicht gemeldet", "未报告", "Non signalé", "보고되지 않음", "No informado", "Non segnalato", "Chưa được báo cáo", "ไม่ได้รายงาน"],
        "quota_observations_table": ["Quota observations", "利用枠の観測", "Kontingentbeobachtungen", "额度观测记录", "Relevés de quota", "할당량 관측", "Observaciones de cuota", "Osservazioni quota", "Các lần ghi nhận hạn mức", "รายการสังเกตโควต้า"],
        "quota_chart_start": ["Start", "開始", "Beginn", "开始", "Début", "시작", "Inicio", "Inizio", "Bắt đầu", "เริ่มต้น"],
        "quota_chart_now": ["Now", "現在", "Jetzt", "现在", "Maintenant", "현재", "Ahora", "Ora", "Hiện tại", "ตอนนี้"],
        "quota_chart_a11y": ["Remaining quota chart from 0 to 100 percent.", "残量を0〜100%で表示するグラフ", "Diagramm des Restkontingents von 0 bis 100 Prozent.", "显示 0 到 100% 剩余额度的图表。", "Graphique du quota restant de 0 à 100 pour cent.", "0~100% 남은 할당량 차트입니다.", "Gráfico de cuota restante de 0 a 100 por ciento.", "Grafico della quota residua da 0 a 100 percento.", "Biểu đồ hạn mức còn lại từ 0 đến 100 phần trăm.", "กราฟโควต้าคงเหลือจาก 0 ถึง 100 เปอร์เซ็นต์"],
        "quota_chart_gap_note": ["Lines break for missing observations or a reset.", "観測がない時間やリセットの前後では線が切れます。", "Linien enden bei fehlenden Beobachtungen oder einem Reset.", "缺少观测记录或重置时，折线会中断。", "Les lignes s’arrêtent en cas de relevé manquant ou de réinitialisation.", "관측 기록이 없거나 재설정되면 선이 끊깁니다.", "Las líneas se interrumpen si faltan observaciones o hay un reinicio.", "Le linee si interrompono in caso di osservazioni mancanti o ripristino.", "Đường bị ngắt khi thiếu lần ghi nhận hoặc khi đặt lại.", "เส้นจะขาดเมื่อไม่มีข้อมูลหรือมีการรีเซ็ต"],
        "refresh": ["Refresh", "再集計", "Aktualisieren", "刷新", "Actualiser", "새로 고침", "Actualizar", "Aggiorna", "Làm mới", "รีเฟรช"],
        "settings": ["Settings…", "設定…", "Einstellungen…", "设置…", "Réglages…", "설정…", "Ajustes…", "Impostazioni…", "Cài đặt…", "การตั้งค่า…"],
        "check_for_updates": ["Check for Updates…", "アップデートを確認…", "Nach Updates suchen…", "检查更新…", "Rechercher les mises à jour…", "업데이트 확인…", "Buscar actualizaciones…", "Controlla aggiornamenti…", "Kiểm tra cập nhật…", "ตรวจสอบอัปเดต…"],
        "quit": ["Quit TKMY", "TKMYを終了", "TKMY beenden", "退出 TKMY", "Quitter TKMY", "TKMY 종료", "Salir de TKMY", "Esci da TKMY", "Thoát TKMY", "ออกจาก TKMY"],
        "weekly_remaining": ["Weekly limit: %@ left", "週次利用制限 残り%@", "Wochenlimit: %@ übrig", "每周限制：剩余 %@", "Limite hebdomadaire : %@ restants", "주간 한도: %@ 남음", "Límite semanal: queda %@", "Limite settimanale: %@ rimasto", "Giới hạn tuần: còn %@", "ขีดจำกัดรายสัปดาห์: เหลือ %@"],
        "used_format": ["%@ used", "使用%@", "%@ verwendet", "已使用 %@", "%@ utilisés", "%@ 사용", "%@ usado", "%@ usato", "Đã dùng %@", "ใช้ไป %@"],
        "reset_format": ["Resets %@", "リセット %@", "Zurücksetzen %@", "重置 %@", "Réinitialisation %@", "재설정 %@", "Se reinicia %@", "Ripristino %@", "Đặt lại %@", "รีเซ็ต %@"],
        "today_tokens": ["Today %@ tokens", "今日 %@トークン", "Heute %@ Token", "今天 %@ 个令牌", "Aujourd’hui %@ jetons", "오늘 %@ 토큰", "Hoy %@ tokens", "Oggi %@ token", "Hôm nay %@ token", "วันนี้ %@ โทเค็น"],
        "no_limit": ["Usage limit unavailable", "利用上限情報なし", "Nutzungslimit nicht verfügbar", "无使用限制信息", "Limite d’utilisation indisponible", "사용 한도 정보 없음", "Límite de uso no disponible", "Limite di utilizzo non disponibile", "Không có giới hạn sử dụng", "ไม่มีข้อมูลขีดจำกัดการใช้งาน"],
        "token_usage_tooltip": ["%@ token usage", "%@のトークン消費", "%@-Token-Nutzung", "%@ 令牌使用量", "Utilisation des jetons %@", "%@ 토큰 사용량", "Uso de tokens de %@", "Utilizzo token %@", "Mức dùng token %@", "การใช้โทเค็น %@"],
        "startup_failed": ["TKMY could not start", "TKMYを起動できません", "TKMY konnte nicht gestartet werden", "无法启动 TKMY", "Impossible de démarrer TKMY", "TKMY를 시작할 수 없습니다", "No se pudo iniciar TKMY", "Impossibile avviare TKMY", "Không thể khởi động TKMY", "ไม่สามารถเริ่ม TKMY ได้"],
        "exit": ["Quit", "終了", "Beenden", "退出", "Quitter", "종료", "Salir", "Esci", "Thoát", "ออก"],
        "updating": ["Updating", "更新中", "Wird aktualisiert", "正在更新", "Mise à jour", "업데이트 중", "Actualizando", "Aggiornamento", "Đang cập nhật", "กำลังอัปเดต"],
        "last_updated": ["Last updated %@", "最終更新 %@", "Zuletzt aktualisiert %@", "最后更新 %@", "Dernière mise à jour %@", "마지막 업데이트 %@", "Última actualización %@", "Ultimo aggiornamento %@", "Cập nhật lần cuối %@", "อัปเดตล่าสุด %@"],
        "source_mismatch": ["Data source mismatch", "データソースが一致しません", "Datenquelle stimmt nicht überein", "数据源不匹配", "La source de données ne correspond pas", "데이터 소스 불일치", "La fuente de datos no coincide", "Origine dati non corrispondente", "Nguồn dữ liệu không khớp", "แหล่งข้อมูลไม่ตรงกัน"],
        "use_viewmodel_for_source": ["Provide a ViewModel for %@.", "%@用のViewModelを指定してください。", "Geben Sie ein ViewModel für %@ an.", "请提供 %@ 的 ViewModel。", "Fournissez un ViewModel pour %@.", "%@용 ViewModel을 제공하세요.", "Proporciona un ViewModel para %@.", "Fornisci un ViewModel per %@.", "Cung cấp ViewModel cho %@.", "โปรดระบุ ViewModel สำหรับ %@"],
        "unreadable_file_one": ["1 file could not be read. The displayed values are partial.", "1件のファイルを読み取れませんでした。表示値は一部です。", "1 Datei konnte nicht gelesen werden. Die angezeigten Werte sind unvollständig.", "无法读取 1 个文件。显示值不完整。", "1 fichier n’a pas pu être lu. Les valeurs affichées sont partielles.", "파일 1개를 읽을 수 없습니다. 표시 값은 일부입니다.", "No se pudo leer 1 archivo. Los valores mostrados son parciales.", "Impossibile leggere 1 file. I valori mostrati sono parziali.", "Không thể đọc 1 tệp. Giá trị hiển thị chưa đầy đủ.", "ไม่สามารถอ่านไฟล์ 1 ไฟล์ได้ ค่าที่แสดงไม่ครบถ้วน"],
        "unreadable_files": ["%lld files could not be read. The displayed values are partial.", "%lld件のファイルを読み取れませんでした。表示値は一部です。", "%lld Dateien konnten nicht gelesen werden. Die angezeigten Werte sind unvollständig.", "无法读取 %lld 个文件。显示值不完整。", "%lld fichiers n’ont pas pu être lus. Les valeurs affichées sont partielles.", "파일 %lld개를 읽을 수 없습니다. 표시 값은 일부입니다.", "No se pudieron leer %lld archivos. Los valores mostrados son parciales.", "Impossibile leggere %lld file. I valori mostrati sono parziali.", "Không thể đọc %lld tệp. Giá trị hiển thị chưa đầy đủ.", "ไม่สามารถอ่านไฟล์ %lld ไฟล์ได้ ค่าที่แสดงไม่ครบถ้วน"],
        "cannot_display": ["Usage cannot be displayed", "利用状況を表示できません", "Nutzung kann nicht angezeigt werden", "无法显示使用情况", "Impossible d’afficher l’utilisation", "사용량을 표시할 수 없음", "No se puede mostrar el uso", "Impossibile mostrare l’utilizzo", "Không thể hiển thị mức sử dụng", "ไม่สามารถแสดงการใช้งานได้"],
        "cannot_read_data": ["Saved data or usage records could not be loaded.", "保存データまたは利用記録を読み込めませんでした。", "Gespeicherte Daten oder Nutzungsprotokolle konnten nicht geladen werden.", "无法加载保存的数据或使用记录。", "Impossible de charger les données ou journaux d’utilisation.", "저장된 데이터 또는 사용 기록을 불러올 수 없습니다.", "No se pudieron cargar los datos guardados o los registros de uso.", "Impossibile caricare dati salvati o registri di utilizzo.", "Không thể tải dữ liệu đã lưu hoặc bản ghi sử dụng.", "ไม่สามารถโหลดข้อมูลที่บันทึกหรือบันทึกการใช้งานได้"],
        "loading_records": ["Loading usage records", "利用記録を読み込み中", "Nutzungsprotokolle werden geladen", "正在加载使用记录", "Chargement des journaux d’utilisation", "사용 기록 불러오는 중", "Cargando registros de uso", "Caricamento registri di utilizzo", "Đang tải bản ghi sử dụng", "กำลังโหลดบันทึกการใช้งาน"],
        "aggregating_locally": ["Found records are being aggregated on this Mac.", "見つかった記録を端末内で集計しています。", "Gefundene Protokolle werden auf diesem Mac zusammengefasst.", "正在此 Mac 上汇总找到的记录。", "Les journaux trouvés sont agrégés sur ce Mac.", "찾은 기록을 이 Mac에서 집계하고 있습니다.", "Los registros encontrados se están agregando en este Mac.", "I registri trovati vengono aggregati su questo Mac.", "Các bản ghi tìm thấy đang được tổng hợp trên máy Mac này.", "กำลังรวมบันทึกที่พบบน Mac เครื่องนี้"],
        "records_not_found": ["No %@ usage records found", "%@の利用記録が見つかりません", "Keine %@-Nutzungsprotokolle gefunden", "未找到 %@ 使用记录", "Aucun journal d’utilisation %@ trouvé", "%@ 사용 기록을 찾을 수 없음", "No se encontraron registros de uso de %@", "Nessun registro di utilizzo %@ trovato", "Không tìm thấy bản ghi sử dụng %@", "ไม่พบบันทึกการใช้งาน %@"],
        "use_then_reload": ["Use it once, then reload.", "一度利用したあとに再読み込みしてください。", "Einmal verwenden und dann neu laden.", "使用一次后重新加载。", "Utilisez-le une fois, puis rechargez.", "한 번 사용한 후 다시 불러오세요.", "Úsalo una vez y vuelve a cargar.", "Usalo una volta, quindi ricarica.", "Hãy sử dụng một lần rồi tải lại.", "ใช้งานหนึ่งครั้งแล้วโหลดใหม่"],
        "searched_locations": ["Locations checked", "確認した場所", "Überprüfte Orte", "检查的位置", "Emplacements vérifiés", "확인한 위치", "Ubicaciones comprobadas", "Posizioni controllate", "Vị trí đã kiểm tra", "ตำแหน่งที่ตรวจสอบ"],
        "daily_token_usage": ["Daily token usage", "日別トークン消費", "Tägliche Token-Nutzung", "每日令牌使用量", "Utilisation quotidienne des jetons", "일별 토큰 사용량", "Uso diario de tokens", "Utilizzo giornaliero dei token", "Mức dùng token hằng ngày", "การใช้โทเค็นรายวัน"],
        "last_12_months": ["Last 12 months", "直近12か月", "Letzte 12 Monate", "最近 12 个月", "12 derniers mois", "최근 12개월", "Últimos 12 meses", "Ultimi 12 mesi", "12 tháng qua", "12 เดือนล่าสุด"],
        "today": ["Today", "今日", "Heute", "今天", "Aujourd’hui", "오늘", "Hoy", "Oggi", "Hôm nay", "วันนี้"],
        "uncalculated_count": ["%lld uncalculated", "%lld件 未算出", "%lld nicht berechnet", "%lld 个未计算", "%lld non calculés", "%lld개 미산출", "%lld sin calcular", "%lld non calcolati", "%lld chưa tính", "%lld รายการยังไม่คำนวณ"],
        "recent_30_day_cost": ["Estimated total for the last 30 days (USD)", "直近30日の推定合計（USD）", "Geschätzte Summe der letzten 30 Tage (USD)", "最近 30 天预计总额（USD）", "Total estimé des 30 derniers jours (USD)", "최근 30일 예상 합계(USD)", "Total estimado de los últimos 30 días (USD)", "Totale stimato ultimi 30 giorni (USD)", "Tổng ước tính 30 ngày qua (USD)", "ยอดรวมโดยประมาณ 30 วันล่าสุด (USD)"],
        "total": ["Total", "合計", "Gesamt", "总计", "Total", "합계", "Total", "Totale", "Tổng", "รวม"],
        "input": ["Input", "入力", "Eingabe", "输入", "Entrée", "입력", "Entrada", "Input", "Đầu vào", "อินพุต"],
        "output": ["Output", "出力", "Ausgabe", "输出", "Sortie", "출력", "Salida", "Output", "Đầu ra", "เอาต์พุต"],
        "estimated_cost": ["Estimated cost (USD)", "推定金額（USD）", "Geschätzte Kosten (USD)", "预计金额（USD）", "Coût estimé (USD)", "예상 금액(USD)", "Coste estimado (USD)", "Costo stimato (USD)", "Chi phí ước tính (USD)", "ค่าใช้จ่ายโดยประมาณ (USD)"],
        "today_usage": ["Today’s usage", "今日の利用状況", "Heutige Nutzung", "今日使用情况", "Utilisation du jour", "오늘 사용량", "Uso de hoy", "Utilizzo odierno", "Mức sử dụng hôm nay", "การใช้งานวันนี้"],
        "cache_create": ["Cache creation", "キャッシュ作成", "Cache-Erstellung", "缓存创建", "Création du cache", "캐시 생성", "Creación de caché", "Creazione cache", "Tạo bộ nhớ đệm", "การสร้างแคช"],
        "cache_read": ["Cache read", "キャッシュ読取", "Cache-Lesen", "缓存读取", "Lecture du cache", "캐시 읽기", "Lectura de caché", "Lettura cache", "Đọc bộ nhớ đệm", "การอ่านแคช"],
        "model_token_usage": ["Token usage by model", "モデル別トークン消費", "Token-Nutzung nach Modell", "按模型的令牌使用量", "Utilisation des jetons par modèle", "모델별 토큰 사용량", "Uso de tokens por modelo", "Utilizzo token per modello", "Mức dùng token theo mô hình", "การใช้โทเค็นตามโมเดล"],
        "no_model_info": ["No model information", "モデル情報なし", "Keine Modellinformationen", "无模型信息", "Aucune information sur le modèle", "모델 정보 없음", "Sin información del modelo", "Nessuna informazione sul modello", "Không có thông tin mô hình", "ไม่มีข้อมูลโมเดล"],
        "selected_day_details": ["Selected day details", "選択日の詳細", "Details zum ausgewählten Tag", "所选日期详情", "Détails du jour sélectionné", "선택한 날짜 세부 정보", "Detalles del día seleccionado", "Dettagli del giorno selezionato", "Chi tiết ngày đã chọn", "รายละเอียดวันที่เลือก"],
        "select_heatmap_day": ["Select a date in the heatmap to view details.", "ヒートマップの日付を選択すると詳細を表示します。", "Wählen Sie ein Datum in der Heatmap, um Details anzuzeigen.", "选择热图中的日期以查看详情。", "Sélectionnez une date dans la carte thermique pour afficher les détails.", "히트맵에서 날짜를 선택하면 세부 정보가 표시됩니다.", "Selecciona una fecha del mapa de calor para ver los detalles.", "Seleziona una data nella mappa termica per vedere i dettagli.", "Chọn ngày trên bản đồ nhiệt để xem chi tiết.", "เลือกวันที่ในฮีตแมปเพื่อดูรายละเอียด"],
        "cost_note": ["Estimated costs prioritize USD values recorded in logs; unrecorded usage is estimated from API prices.", "推定金額はログ記録済みUSDを優先し、未記録分はAPI単価から算出した参考値です。", "Geschätzte Kosten priorisieren protokollierte USD-Werte; nicht erfasste Nutzung wird anhand der API-Preise geschätzt.", "预计金额优先使用日志中的 USD 值；未记录的使用量按 API 价格估算。", "Les coûts estimés privilégient les montants USD des journaux ; le reste est estimé selon les tarifs API.", "예상 금액은 로그에 기록된 USD를 우선하며, 미기록분은 API 가격으로 추정합니다.", "Los costes estimados priorizan los valores USD registrados; el resto se estima con precios de API.", "I costi stimati usano prima i valori USD registrati; il resto è stimato dai prezzi API.", "Chi phí ước tính ưu tiên giá trị USD trong nhật ký; phần chưa ghi được ước tính theo giá API.", "ค่าใช้จ่ายโดยประมาณใช้ค่า USD ในบันทึกก่อน ส่วนที่ไม่บันทึกจะประเมินจากราคา API"],
        "price_table": ["Prices %@", "価格表 %@", "Preise %@", "价格表 %@", "Tarifs %@", "가격표 %@", "Precios %@", "Prezzi %@", "Bảng giá %@", "ตารางราคา %@"],
        "less": ["Less", "少", "Weniger", "少", "Moins", "적음", "Menos", "Meno", "Ít", "น้อย"],
        "more": ["More", "多", "Mehr", "多", "Plus", "많음", "Más", "Più", "Nhiều", "มาก"],
        "heatmap_a11y": ["%@ token usage. Usage increases as the color moves from teal toward red.", "%@のトークン消費。ティールから赤に近づくほど利用量が多い", "%@-Token-Nutzung. Je röter die Farbe, desto höher die Nutzung.", "%@ 令牌使用量。颜色从青色趋向红色表示使用量增加。", "Utilisation des jetons %@. Plus la couleur tend vers le rouge, plus l’utilisation augmente.", "%@ 토큰 사용량. 청록색에서 빨간색에 가까울수록 사용량이 많습니다.", "Uso de tokens de %@. El uso aumenta del verde azulado al rojo.", "Utilizzo token %@. L’utilizzo aumenta dal verde acqua al rosso.", "Mức dùng token %@. Màu càng chuyển từ xanh ngọc sang đỏ thì mức dùng càng cao.", "การใช้โทเค็น %@ ยิ่งสีเปลี่ยนจากเขียวอมฟ้าไปแดงยิ่งใช้งานมาก"],
        "outside_period": ["Outside range", "期間外", "Außerhalb des Zeitraums", "超出范围", "Hors période", "기간 외", "Fuera del período", "Fuori intervallo", "Ngoài khoảng thời gian", "นอกช่วงเวลา"],
        "tokens_format": ["%@ tokens", "%@トークン", "%@ Token", "%@ 个令牌", "%@ jetons", "%@ 토큰", "%@ tokens", "%@ token", "%@ token", "%@ โทเค็น"],
        "model_not_recorded": ["Model not recorded", "モデル記録なし", "Modell nicht erfasst", "未记录模型", "Modèle non enregistré", "모델 기록 없음", "Modelo no registrado", "Modello non registrato", "Không ghi mô hình", "ไม่ได้บันทึกโมเดล"],
        "model_missing_help": ["These tokens do not include a model name in the usage record.", "利用記録にモデル名が含まれていないトークンです。", "Für diese Token enthält das Nutzungsprotokoll keinen Modellnamen.", "这些令牌的使用记录中不含模型名称。", "Le journal d’utilisation de ces jetons ne contient pas de nom de modèle.", "사용 기록에 모델 이름이 없는 토큰입니다.", "Estos tokens no incluyen un nombre de modelo en el registro de uso.", "Questi token non includono il nome del modello nel registro di utilizzo.", "Các token này không có tên mô hình trong bản ghi sử dụng.", "โทเค็นเหล่านี้ไม่มีชื่อโมเดลในบันทึกการใช้งาน"],
        "reload": ["Reload", "再読み込み", "Neu laden", "重新加载", "Recharger", "다시 불러오기", "Recargar", "Ricarica", "Tải lại", "โหลดใหม่"],
        "cannot_calculate": ["Unavailable", "算出不可", "Nicht verfügbar", "无法计算", "Indisponible", "산출 불가", "No disponible", "Non disponibile", "Không khả dụng", "ไม่พร้อมใช้งาน"],
        "stale_history": ["Current usage records were not found, so saved history is being shown.", "現在の利用記録が見つからないため、端末に保存済みの履歴を表示しています。", "Aktuelle Nutzungsprotokolle wurden nicht gefunden; gespeicherte Verlaufsdaten werden angezeigt.", "未找到当前使用记录，因此显示已保存的历史记录。", "Les journaux actuels sont introuvables ; l’historique enregistré est affiché.", "현재 사용 기록을 찾지 못해 저장된 기록을 표시합니다.", "No se encontraron registros actuales; se muestra el historial guardado.", "I registri attuali non sono stati trovati; viene mostrata la cronologia salvata.", "Không tìm thấy bản ghi hiện tại nên lịch sử đã lưu được hiển thị.", "ไม่พบบันทึกการใช้งานปัจจุบัน จึงแสดงประวัติที่บันทึกไว้"],
    ]
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
