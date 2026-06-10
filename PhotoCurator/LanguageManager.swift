import Foundation
import Combine

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english  = "en"

    var id: Self { self }
    var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english:  return "English"
        }
    }
    var flag: String {
        switch self {
        case .japanese: return "🇯🇵"
        case .english:  return "🇺🇸"
        }
    }
}

// MARK: - LanguageManager

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "ja"
        language = AppLanguage(rawValue: saved) ?? .japanese
    }

    var isJapanese: Bool { language == .japanese }

    func s(_ ja: String, _ en: String) -> String {
        isJapanese ? ja : en
    }
}

// MARK: - Localized Strings

extension LanguageManager {
    // MARK: App
    var appTitle: String          { s("Snap Sort by YUDAIKUNZ", "Snap Sort by YUDAIKUNZ") }

    // MARK: HomeView
    var rangeDay: String          { s("日", "Day") }
    var rangeMonth: String        { s("月", "Month") }
    var rangeYear: String         { s("年", "Year") }
    var rangeAll: String          { s("すべて", "All") }
    var allPhotos: String         { s("すべての写真", "All Photos") }
    var analyzeButton: String     { s("分析する", "Analyze") }
    var analyzing: String         { s("写真を分析中…", "Analyzing photos…") }
    var noGroups: String          { s("重複写真なし", "No Duplicates Found") }
    var noGroupsDesc: String      { s("似た写真が見つかりませんでした\n条件を変えて再分析してみてください",
                                      "No similar photos found.\nTry a different range and analyze again.") }

    // MARK: GroupList
    var groupCount: String        { s("グループ", "Groups") }
    var deleteTarget: String      { s("削除候補", "To Delete") }
    var groupList: String         { s("グループ一覧", "Group List") }
    var bulkDelete: String        { s("一括削除", "Delete All") }
    var canDelete: String         { s("枚削除可能", " deletable") }
    var photoCount: String        { s("枚", " photos") }

    // MARK: GroupDetail
    var groupDetail: String       { s("グループ詳細", "Group Detail") }
    var aiPick: String            { s("AI推薦", "AI Pick") }
    var candidatePhotos: String   { s("候補写真", "Candidates") }
    var candidateHint: String     { s("写真→拡大　アイコン→残す/削除", "Tap photo to zoom · Icon to keep/delete") }
    var keepCount: String         { s("枚残す", " to keep") }
    var deleteButton: String      { s("枚を削除する", " photos to delete") }

    // MARK: ZoomView
    var keepPhoto: String         { s("残す写真", "Keeping") }
    var deletePhoto: String       { s("削除予定", "To Delete") }
    var changeToDelete: String    { s("削除に変更", "Mark for Delete") }
    var changeToKeep: String      { s("残すに変更", "Keep This") }
    var close: String             { s("閉じる", "Close") }

    // MARK: Confirmation
    var deleteConfirm: String     { s("削除する", "Delete") }
    var cancel: String            { s("キャンセル", "Cancel") }

    // MARK: Settings
    var settings: String          { s("設定", "Settings") }
    var display: String           { s("表示", "Display") }
    var darkMode: String          { s("ダークモード", "Dark Mode") }
    var languageSetting: String   { s("言語", "Language") }
    var aiCriteria: String        { s("AI選定の基準", "AI Selection Criteria") }
    var notes: String             { s("注意事項", "Notes") }
    var credits: String           { s("クレジット", "Credits") }

    // MARK: Settings Detail
    var criteriaSharpnessTitle: String  { s("シャープネス（鮮明さ）", "Sharpness") }
    var criteriaSharpnessDesc: String   { s("ラプラシアン分散を用いてピンボケやブレを数値化します。値が高いほど鮮明な写真と判定されます。",
                                            "Blur and camera shake are measured using Laplacian variance. Higher values indicate sharper images.") }
    var criteriaExposureTitle: String   { s("露出", "Exposure") }
    var criteriaExposureDesc: String    { s("画像全体の平均輝度を計算し、明るすぎ・暗すぎを検出します。適正露出（中間輝度）に近いほど高スコアになります。",
                                            "Average luminance is calculated to detect over/underexposure. Images closer to ideal brightness score higher.") }
    var criteriaFaceTitle: String       { s("顔品質", "Face Quality") }
    var criteriaFaceDesc: String        { s("Appleの顔認識技術を使って顔の品質スコアを算出します。複数人の場合は全員の平均値で評価します。",
                                            "Apple's face detection technology scores face quality. When multiple faces are present, the average score is used.") }
    var criteriaEyeTitle: String        { s("目つぶり検出", "Blink Detection") }
    var criteriaEyeDesc: String         { s("顔のランドマーク（目の6点座標）から目の開き具合を計算します。目が閉じていると判定された場合はスコアにペナルティが加算されます。",
                                            "Eye openness is calculated from facial landmarks (6 eye points). Closed eyes result in a score penalty.") }

    var note1: String { s("AIの判定は100%正確ではありません。削除前に必ず写真をご確認ください。",
                           "AI judgment is not 100% accurate. Always review photos before deleting.") }
    var note2: String { s("すべての処理はお使いの端末内で行われます。写真データが外部に送信されることは一切ありません。",
                           "All processing is done on your device. Photo data is never sent externally.") }
    var note3: String { s("削除した写真はiOSの「最近削除した項目」に30日間保存されます。誤って削除した場合でも復元できます。",
                           "Deleted photos are kept in iOS 'Recently Deleted' for 30 days and can be restored.") }
    var note4: String { s("顔認識・目つぶり検出は逆光・横顔・マスク着用時など条件によって精度が下がる場合があります。",
                           "Face and blink detection accuracy may decrease under backlight, side profiles, or mask-wearing conditions.") }

    var creditDeveloper: String  { s("開発者", "Developer") }
    var creditVersion: String    { s("バージョン", "Version") }
    var creditTech: String       { s("使用技術", "Technologies") }
    var creditOS: String         { s("対応OS", "Requires") }

    // MARK: Permission
    var permissionTitle: String   { s("写真へのアクセスが必要です", "Photo Access Required") }
    var permissionDesc: String    { s("重複写真を検出・整理するために\nフォトライブラリへのアクセスを許可してください",
                                      "Please allow access to your photo library\nto detect and organize duplicate photos.") }
    var permissionButton: String  { s("アクセスを許可する", "Allow Access") }
    var deniedTitle: String       { s("アクセスが拒否されています", "Access Denied") }
    var deniedDesc: String        { s("設定アプリからフォトライブラリへの\nアクセスを許可してください",
                                      "Please allow photo library access\nin the Settings app.") }
    var openSettings: String      { s("設定を開く", "Open Settings") }
}
