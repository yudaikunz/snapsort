import SwiftUI
import Photos
import PhotosUI
import StoreKit
import Combine

// MARK: - Design Tokens

extension Color {
    static let accent = Color.indigo
    static let cardBackground = Color(.secondarySystemBackground)
    static let deleteRed = Color(red: 1, green: 0.27, blue: 0.23)
    static let keepGreen = Color(red: 0.2, green: 0.78, blue: 0.35)
}

// MARK: - AnalysisRange

enum AnalysisRange: String, CaseIterable, Identifiable {
    case day   = "day"
    case month = "month"
    case year  = "year"
    case all   = "all"
    var id: Self { self }

    func displayName(_ lm: LanguageManager) -> String {
        switch self {
        case .day:   return lm.s("日", "Day")
        case .month: return lm.s("月", "Month")
        case .year:  return lm.s("年", "Year")
        case .all:   return lm.s("すべて", "All")
        }
    }
}

// MARK: - Root ContentView

struct ContentView: View {
    @StateObject private var library = PhotoLibraryManager.shared
    @StateObject private var viewModel = CuratorViewModel()
    @StateObject private var lm = LanguageManager.shared
    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false

    var body: some View {
        Group {
            if !hasLaunchedBefore {
                LanguageSelectionView {
                    hasLaunchedBefore = true
                }
            } else {
                switch library.authorizationStatus {
                case .authorized, .limited:
                    if library.isLoading {
                        LibraryLoadingView()
                    } else {
                        MainTabView(viewModel: viewModel)
                    }
                case .denied, .restricted:
                    PermissionDeniedView()
                default:
                    PermissionRequestView {
                        Task { await library.requestAuthorization() }
                    }
                }
            }
        }
        .environmentObject(lm)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .task {
            if hasLaunchedBefore {
                library.checkCurrentAuthorization()
                if library.authorizationStatus == .authorized || library.authorizationStatus == .limited {
                    await library.fetchAllPhotos()
                    await library.fetchAllVideos()
                }
            }
        }
    }
}

// MARK: - LanguageSelectionView

struct LanguageSelectionView: View {
    let onComplete: () -> Void
    @StateObject private var lm = LanguageManager.shared
    @State private var selected: AppLanguage = .japanese

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.64),
                                     Color(red: 0.39, green: 0.40, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // アイコン＋タイトル
                VStack(spacing: 16) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                    Text("Snap Sort")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("by YUDAIKUNZ")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }

                // 言語選択
                VStack(spacing: 12) {
                    Text("言語を選択 / Select Language")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.9))

                    HStack(spacing: 16) {
                        ForEach(AppLanguage.allCases) { lang in
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    selected = lang
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    Text(lang.flag)
                                        .font(.system(size: 40))
                                    Text(lang.displayName)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(selected == lang ? Color.accent : .white)
                                }
                                .frame(width: 130, height: 100)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(selected == lang
                                              ? .white
                                              : Color.white.opacity(0.15))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(selected == lang ? Color.white : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                // 開始ボタン
                Button {
                    lm.language = selected
                    onComplete()
                } label: {
                    Text(selected == .japanese ? "はじめる" : "Get Started")
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white)
                        .foregroundStyle(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    @ObservedObject var viewModel: CuratorViewModel
    @ObservedObject private var lm = LanguageManager.shared

    var body: some View {
        TabView {
            HomeView(viewModel: viewModel)
                .tabItem {
                    Label(lm.s("写真整理", "Photos"), systemImage: "photo.stack.fill")
                }

            VideoFrameExtractorView()
                .tabItem {
                    Label(lm.s("動画抽出", "Clip"), systemImage: "film.fill")
                }

            SettingsView()
                .tabItem {
                    Label(lm.s("設定", "Settings"), systemImage: "gearshape.fill")
                }
        }
        .tint(Color.accent)
    }
}

// MARK: - HomeView

struct HomeView: View {
    @ObservedObject var viewModel: CuratorViewModel
    @ObservedObject private var library = PhotoLibraryManager.shared
    @EnvironmentObject private var lm: LanguageManager
    @ObservedObject private var personRegistry = PersonRegistry.shared
    @ObservedObject private var tagRegistry = TagRegistry.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @State private var selectedRange: AnalysisRange = .all
    @State private var selectedDate: Date = Date()
    @State private var selectedMonthYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedDay: Int = Calendar.current.component(.day, from: Date())
    // 人物フィルター
    @State private var selectedPersonID: UUID? = nil
    @State private var showPersonFilter = false
    @State private var showAddPersonAlert = false
    @State private var newPersonName = ""
    // タグフィルター
    @State private var selectedTagID: UUID? = nil
    @State private var showTagFilter = false
    @State private var showAddTagAlert = false
    @State private var newTagName = ""
    @State private var newTagColorIndex = 0
    @State private var tagPendingDelete: RegisteredTag? = nil
    // お気に入りフィルター
    @State private var showFavoritesOnly = false

    private let currentYear = Calendar.current.component(.year, from: Date())
    private var yearRange: [Int] { Array((2000...currentYear).reversed()) }
    private let monthNames = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    var filteredAssets: [PHAsset] {
        let calendar = Calendar.current
        var assets = library.allAssets.filter { asset in
            guard let date = asset.creationDate else { return selectedRange == .all }
            switch selectedRange {
            case .day:
                return calendar.component(.year, from: date) == selectedYear
                    && calendar.component(.month, from: date) == selectedMonth
                    && calendar.component(.day, from: date) == selectedDay
            case .month:
                return calendar.component(.year, from: date) == selectedMonthYear
                    && calendar.component(.month, from: date) == selectedMonth
            case .year:  return calendar.component(.year, from: date) == selectedYear
            case .all:   return true
            }
        }
        // 人物フィルター
        if let personID = selectedPersonID,
           let person = personRegistry.persons.first(where: { $0.id == personID }) {
            let ids = Set(person.photoIDs)
            assets = assets.filter { ids.contains($0.localIdentifier) }
        }
        // お気に入りフィルター
        if showFavoritesOnly {
            assets = assets.filter { favoritesStore.isFavorite($0.localIdentifier) }
        }
        // タグフィルター
        if let tagID = selectedTagID,
           let tag = tagRegistry.tags.first(where: { $0.id == tagID }) {
            let ids = Set(tag.photoIDs)
            assets = assets.filter { ids.contains($0.localIdentifier) }
        }
        return assets
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 20) {
                        // ヘッダーカード
                        headerCard

                        // 分析結果
                        if viewModel.isAnalyzing {
                            analyzingCard
                        } else if !viewModel.groups.isEmpty {
                            resultsSection
                        } else {
                            emptyCard
                        }

                        Color.clear.frame(height: 80)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // 分析ボタン（下部固定）
                analyzeButton
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { favoritesStore.syncFromAssets(library.allAssets) }
        .confirmationDialog(
            tagPendingDelete.map { lm.s("タグ「\($0.name)」を削除しますか？", "Delete tag “\($0.name)”?") } ?? "",
            isPresented: Binding(
                get: { tagPendingDelete != nil },
                set: { if !$0 { tagPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(lm.s("削除", "Delete"), role: .destructive) {
                if let tag = tagPendingDelete {
                    if selectedTagID == tag.id { selectedTagID = nil }
                    tagRegistry.deleteTag(id: tag.id)
                }
                tagPendingDelete = nil
            }
            Button(lm.s("キャンセル", "Cancel"), role: .cancel) { tagPendingDelete = nil }
        } message: {
            Text(lm.s("写真は削除されません。写真アプリのアルバム（まとめ）も削除されます。",
                      "Your photos will not be deleted. The matching album in the Photos app will also be removed."))
        }
    }

    // MARK: - Sub Views

    private var headerCard: some View {
        VStack(spacing: 16) {
            // タイトル＋設定ボタン
            HStack {
                Text(lm.s("写真整理", "Photos"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // 範囲セレクター
            HStack(spacing: 0) {
                ForEach(AnalysisRange.allCases) { range in
                    Button {
                        withAnimation(.spring(response: 0.3)) { selectedRange = range }
                    } label: {
                        Text(range.displayName(lm))
                            .font(.subheadline.weight(selectedRange == range ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedRange == range
                                    ? Color.accent
                                    : Color.clear
                            )
                            .foregroundStyle(selectedRange == range ? .white : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // 日付指定UI
            dateSelectorView

            // 人物フィルター
            Divider()
            personFilterSection
            // お気に入りフィルター
            Divider()
            favoritesFilterSection
            // タグフィルター
            Divider()
            tagFilterSection
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .alert(lm.s("人物を追加", "Add Person"), isPresented: $showAddPersonAlert) {
            TextField(lm.s("名前を入力", "Enter name"), text: $newPersonName)
            Button(lm.s("追加", "Add")) {
                let name = newPersonName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { personRegistry.addPerson(name: name) }
                newPersonName = ""
            }
            Button(lm.s("キャンセル", "Cancel"), role: .cancel) { newPersonName = "" }
        }
        .alert(lm.s("タグを追加", "Add Tag"), isPresented: $showAddTagAlert) {
            TextField(lm.s("タグ名を入力", "Enter tag name"), text: $newTagName)
            Button(lm.s("追加", "Add")) {
                let name = newTagName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { tagRegistry.addTag(name: name, colorIndex: newTagColorIndex) }
                newTagName = ""
            }
            Button(lm.s("キャンセル", "Cancel"), role: .cancel) { newTagName = "" }
        }
    }

    // MARK: - Person Filter

    private var personFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // トグルボタン
            Button {
                withAnimation(.spring(response: 0.3)) {
                    showPersonFilter.toggle()
                    if !showPersonFilter { selectedPersonID = nil }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedPersonID != nil ? "person.fill" : "person")
                        .font(.caption.bold())
                    if let id = selectedPersonID,
                       let name = personRegistry.persons.first(where: { $0.id == id })?.name {
                        Text(name)
                            .font(.caption.bold())
                    } else {
                        Text(lm.s("人物フィルター", "Person Filter"))
                            .font(.caption.bold())
                    }
                    Spacer()
                    if selectedPersonID != nil {
                        Circle().fill(Color.accent).frame(width: 8, height: 8)
                    }
                    Image(systemName: showPersonFilter ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(showPersonFilter || selectedPersonID != nil ? Color.accent : .secondary)
            }
            .buttonStyle(.plain)

            if showPersonFilter {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if personRegistry.persons.isEmpty {
                            Label(
                                lm.s("写真を長押しして人物を登録", "Long-press a photo to register people"),
                                systemImage: "person.badge.plus"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            ForEach(personRegistry.persons) { person in
                                let isSelected = selectedPersonID == person.id
                                Button {
                                    withAnimation(.spring(response: 0.2)) {
                                        selectedPersonID = isSelected ? nil : person.id
                                    }
                                } label: {
                                    Label(person.name, systemImage: "person.fill")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? Color.accent : Color(.tertiarySystemBackground))
                                        .foregroundStyle(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        if selectedPersonID == person.id { selectedPersonID = nil }
                                        personRegistry.deletePerson(id: person.id)
                                    } label: {
                                        Label(lm.s("削除", "Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }

                        // 追加ボタン
                        Button { showAddPersonAlert = true } label: {
                            Label(lm.s("追加", "Add"), systemImage: "plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemBackground))
                                .foregroundStyle(Color.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Favorites Filter

    private var favoritesFilterSection: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                showFavoritesOnly.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                    .font(.caption.bold())
                    .foregroundStyle(showFavoritesOnly ? Color.pink : .secondary)
                Text(lm.s("お気に入りのみ", "Favorites Only"))
                    .font(.caption.bold())
                    .foregroundStyle(showFavoritesOnly ? Color.pink : .secondary)
                Spacer()
                if showFavoritesOnly {
                    Circle().fill(Color.pink).frame(width: 8, height: 8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tag Filter

    private var tagFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    showTagFilter.toggle()
                    if !showTagFilter { selectedTagID = nil }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedTagID != nil ? "tag.fill" : "tag")
                        .font(.caption.bold())
                    if let id = selectedTagID,
                       let name = tagRegistry.tags.first(where: { $0.id == id })?.name {
                        Text(name)
                            .font(.caption.bold())
                    } else {
                        Text(lm.s("タグフィルター", "Tag Filter"))
                            .font(.caption.bold())
                    }
                    Spacer()
                    if selectedTagID != nil {
                        Circle().fill(Color.accent).frame(width: 8, height: 8)
                    }
                    Image(systemName: showTagFilter ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(showTagFilter || selectedTagID != nil ? Color.accent : .secondary)
            }
            .buttonStyle(.plain)

            if showTagFilter {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if tagRegistry.tags.isEmpty {
                            Label(
                                lm.s("写真を長押ししてタグを作成", "Long-press a photo to create tags"),
                                systemImage: "tag.badge.plus"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            ForEach(tagRegistry.tags) { tag in
                                let isSelected = selectedTagID == tag.id
                                Button {
                                    withAnimation(.spring(response: 0.2)) {
                                        selectedTagID = isSelected ? nil : tag.id
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.tagColor(tag.colorIndex))
                                            .frame(width: 8, height: 8)
                                        Text(tag.name)
                                            .font(.caption.bold())
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.tagColor(tag.colorIndex) : Color(.tertiarySystemBackground))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        tagPendingDelete = tag
                                    } label: {
                                        Label(lm.s("削除", "Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }

                        // 追加ボタン
                        Button { showAddTagAlert = true } label: {
                            Label(lm.s("追加", "Add"), systemImage: "plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemBackground))
                                .foregroundStyle(Color.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var maxDayInMonth: Int {
        let calendar = Calendar.current
        let components = DateComponents(year: selectedMonthYear, month: selectedMonth)
        let date = calendar.date(from: components) ?? Date()
        return calendar.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    @ViewBuilder
    private var dateSelectorView: some View {
        if selectedRange == .day {
            VStack(spacing: 12) {
                SliderSelector(label: lm.s("年", "Year"), value: $selectedYear, minVal: 2000, maxVal: currentYear) {
                    lm.s(String(format: "%d年", selectedYear), String(format: "%d", selectedYear))
                }
                SliderSelector(label: lm.s("月", "Month"), value: $selectedMonth, minVal: 1, maxVal: 12) {
                    lm.isJapanese ? monthNames[selectedMonth - 1] : Calendar.current.shortMonthSymbols[selectedMonth - 1]
                }
                SliderSelector(label: lm.s("日", "Day"), value: $selectedDay, minVal: 1, maxVal: maxDayInMonth) {
                    lm.s(String(format: "%d日", selectedDay), String(format: "%d", selectedDay))
                }
            }
        } else if selectedRange == .month {
            VStack(spacing: 12) {
                SliderSelector(label: lm.s("年", "Year"), value: $selectedMonthYear, minVal: 2000, maxVal: currentYear) {
                    lm.s(String(format: "%d年", selectedMonthYear), String(format: "%d", selectedMonthYear))
                }
                SliderSelector(label: lm.s("月", "Month"), value: $selectedMonth, minVal: 1, maxVal: 12) {
                    lm.isJapanese ? monthNames[selectedMonth - 1] : Calendar.current.shortMonthSymbols[selectedMonth - 1]
                }
            }
        } else if selectedRange == .year {
            SliderSelector(label: lm.s("年", "Year"), value: $selectedYear, minVal: 2000, maxVal: currentYear) {
                lm.s(String(format: "%d年", selectedYear), String(format: "%d", selectedYear))
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(Color.accent)
                Text("\(lm.allPhotos) \(library.allAssets.count)\(lm.photoCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var analyzeButton: some View {
        Button {
            viewModel.startAnalysis(assets: filteredAssets)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.body.bold())
                Text("\(lm.analyzeButton)（\(filteredAssets.count)\(lm.photoCount)）")
                    .font(.body.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                filteredAssets.isEmpty || viewModel.isAnalyzing
                    ? Color(.systemGray4)
                    : Color.accent
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.accent.opacity(0.4), radius: 8, y: 4)
        }
        .disabled(viewModel.isAnalyzing || filteredAssets.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.08), radius: 8, y: -4)
        )
    }

    private var analyzingCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundStyle(Color.accent)
                .symbolEffect(.pulse)
            Text(lm.analyzing)
                .font(.headline)
            ProgressView(value: viewModel.progress)
                .tint(Color.accent)
                .padding(.horizontal, 20)
            Text("\(Int(viewModel.progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                viewModel.cancelAnalysis()
            } label: {
                Text(lm.stopAnalysis)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Color.deleteRed)
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var emptyCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.keepGreen)
            Text(lm.noGroups)
                .font(.headline)
            Text(lm.noGroupsDesc)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var resultsSection: some View {
        VStack(spacing: 12) {
            // サマリーカード
            let totalDuplicates = viewModel.groups.reduce(0) { $0 + $1.duplicateCount }
            HStack(spacing: 16) {
                summaryItem(value: "\(viewModel.groups.count)", label: lm.groupCount, icon: "square.stack.3d.up", color: Color.accent)
                Divider().frame(height: 40)
                summaryItem(value: "\(totalDuplicates)", label: lm.deleteTarget, icon: "trash", color: Color.deleteRed)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

            GroupListView(viewModel: viewModel)
        }
    }

    private func summaryItem(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - GroupListView

struct GroupListView: View {
    @ObservedObject var viewModel: CuratorViewModel
    @EnvironmentObject private var lm: LanguageManager
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(lm.groupList)
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(lm.bulkDelete, systemImage: "trash")
                        .font(.subheadline)
                }
                .disabled(viewModel.selectedForDeletion.isEmpty)
            }
            .padding(.horizontal, 4)

            ForEach(viewModel.groups) { group in
                NavigationLink(destination: GroupDetailView(group: group, viewModel: viewModel)) {
                    GroupRowView(group: group)
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(
            lm.s("\(viewModel.selectedForDeletion.count) グループの重複写真を削除しますか？",
                 "Delete duplicates in \(viewModel.selectedForDeletion.count) groups?"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(lm.deleteConfirm, role: .destructive) {
                Task { await viewModel.deleteSelectedDuplicates() }
            }
            Button(lm.cancel, role: .cancel) {}
        }
    }
}

// MARK: - GroupRowView

struct GroupRowView: View {
    let group: PhotoGroup
    @EnvironmentObject private var lm: LanguageManager

    var body: some View {
        HStack(spacing: 12) {
            // サムネイル
            AssetThumbnailView(asset: group.bestAsset, size: CGSize(width: 72, height: 72))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.keepGreen, lineWidth: 2)
                )

            // 情報
            VStack(alignment: .leading, spacing: 5) {
                if let date = group.bestAsset.creationDate {
                    let locale = Locale(identifier: lm.isJapanese ? "ja_JP" : "en_US")
                    Text(date.formatted(.dateTime.year().month().day().locale(locale)))
                        .font(.body.bold())
                }
                HStack(spacing: 6) {
                    Label("\(group.assets.count)\(lm.photoCount)", systemImage: "photo.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(lm.s("\(group.duplicateCount)枚削除可能", "\(group.duplicateCount)\(lm.canDelete)"))
                        .font(.caption.bold())
                        .foregroundStyle(Color.deleteRed)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

// MARK: - GroupDetailView

struct ZoomedPhoto: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let index: Int
}

/// PHAsset を sheet(item:) に渡すための Identifiable ラッパー
struct TaggableAsset: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

struct GroupDetailView: View {
    let group: PhotoGroup
    @ObservedObject var viewModel: CuratorViewModel
    @EnvironmentObject private var lm: LanguageManager
    @ObservedObject private var personRegistry = PersonRegistry.shared
    @ObservedObject private var tagRegistry = TagRegistry.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @State private var keepIndices: Set<Int>
    @State private var showingDeleteConfirmation = false
    @State private var zoomedPhoto: ZoomedPhoto?
    @State private var taggingAsset: TaggableAsset?
    @Environment(\.dismiss) private var dismiss

    init(group: PhotoGroup, viewModel: CuratorViewModel) {
        self.group = group
        self.viewModel = viewModel
        _keepIndices = State(initialValue: group.effectiveKeepIndices)
    }

    var assetsToDelete: [PHAsset] {
        if keepIndices.isEmpty { return group.assets }
        return group.assets.enumerated()
            .filter { !keepIndices.contains($0.offset) }
            .map { $0.element }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 20) {
                    // AI推薦ヒーロー写真
                    bestPhotoSection

                    // 候補グリッド
                    candidateGridSection

                    Color.clear.frame(height: 88)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // 削除ボタン（固定）
            deleteBar
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lm.groupDetail)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog(
            lm.s("\(assetsToDelete.count) 枚の写真を削除しますか？",
                 "Delete \(assetsToDelete.count) photos?"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(lm.deleteConfirm, role: .destructive) {
                Task {
                    await viewModel.deleteFromGroup(groupID: group.id, assets: assetsToDelete)
                    dismiss()
                }
            }
            Button(lm.cancel, role: .cancel) {}
        }
        .sheet(item: $zoomedPhoto) { zoomed in
            PhotoZoomView(
                assets: group.assets,
                initialIndex: zoomed.index,
                keepIndices: keepIndices
            ) { index, action in
                switch action {
                case .keep:   keepIndices.insert(index)
                case .remove: keepIndices.remove(index)
                }
            }
        }
        .sheet(item: $taggingAsset) { taggable in
            PhotoActionsSheet(asset: taggable.asset)
                .environmentObject(lm)
        }
        .onAppear { favoritesStore.syncFromAssets(group.assets) }
    }

    // MARK: - Sections

    private var bestPhotoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(lm.aiPick, systemImage: "sparkles")
                .font(.subheadline.bold())
                .foregroundStyle(Color.accent)

            AssetThumbnailView(
                asset: group.bestAsset,
                size: CGSize(width: UIScreen.main.bounds.width - 32, height: 260)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture {
                zoomedPhoto = ZoomedPhoto(asset: group.bestAsset, index: group.bestAssetIndex)
            }

            if let score = group.bestScore {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(score.recommendationReasons(lm: lm), id: \.self) { reason in
                            Text(reason)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.keepGreen.opacity(0.15))
                                .foregroundStyle(Color.keepGreen)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var candidateGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lm.candidatePhotos)
                        .font(.subheadline.bold())
                    Text(lm.candidateHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(keepIndices.count)\(lm.keepCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.keepGreen.opacity(0.15))
                    .foregroundStyle(Color.keepGreen)
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Array(group.assets.enumerated()), id: \.offset) { index, asset in
                    let isKept = keepIndices.contains(index)
                    let isFav = favoritesStore.isFavorite(asset.localIdentifier)
                    let taggedPersons = personRegistry.taggedPersons(for: asset.localIdentifier)
                    let appliedTags = tagRegistry.appliedTags(for: asset.localIdentifier)
                    ZStack {
                        // 写真タップ → 拡大 / 長押し → アクションシート
                        AssetThumbnailView(asset: asset, size: CGSize(width: 120, height: 120))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isKept ? Color.keepGreen : Color.deleteRed, lineWidth: 3)
                            )
                            .opacity(isKept ? 1.0 : 0.6)
                            .onTapGesture {
                                zoomedPhoto = ZoomedPhoto(asset: asset, index: index)
                            }
                            .onLongPressGesture {
                                taggingAsset = TaggableAsset(asset: asset)
                            }

                        // オーバーレイ（ハート・残す消す・バッジ）
                        VStack(spacing: 0) {
                            HStack(alignment: .top) {
                                // ハートボタン（左）
                                Button {
                                    Task { await favoritesStore.toggle(asset: asset) }
                                } label: {
                                    Image(systemName: isFav ? "heart.fill" : "heart")
                                        .font(.title2)
                                        .foregroundStyle(isFav ? Color.pink : .white)
                                        .shadow(color: .black.opacity(0.4), radius: 1)
                                        .padding(8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                // 残す/消すボタン（右）
                                Button {
                                    withAnimation(.spring(response: 0.2)) {
                                        if isKept { keepIndices.remove(index) }
                                        else      { keepIndices.insert(index) }
                                    }
                                } label: {
                                    Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(isKept ? Color.keepGreen : Color.deleteRed)
                                        .background(Circle().fill(.white).padding(3))
                                        .padding(8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            // バッジ行（下部）
                            HStack(alignment: .bottom, spacing: 3) {
                                // 人物バッジ（左）
                                if !taggedPersons.isEmpty {
                                    HStack(spacing: 2) {
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 8, weight: .bold))
                                        Text(taggedPersons.prefix(2).map { String($0.name.prefix(3)) }.joined(separator: "・"))
                                            .font(.system(size: 8, weight: .bold))
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Color.indigo.opacity(0.88))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                }
                                // タグカラーバッジ
                                if !appliedTags.isEmpty {
                                    HStack(spacing: 2) {
                                        ForEach(appliedTags.prefix(3)) { tag in
                                            Circle()
                                                .fill(Color.tagColor(tag.colorIndex))
                                                .frame(width: 7, height: 7)
                                        }
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                }
                                Spacer()
                                // AI推薦バッジ（右）
                                if index == group.bestAssetIndex {
                                    Text(lm.aiPick)
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.accent.opacity(0.9))
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(6)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var deleteBar: some View {
        let isDeleteAll = keepIndices.isEmpty
        let label = isDeleteAll
            ? lm.s("グループ全て削除", "Delete All in Group")
            : "\(assetsToDelete.count)\(lm.deleteButton)"

        return Button {
            showingDeleteConfirmation = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isDeleteAll ? "trash.fill" : "trash")
                    .font(.body.bold())
                Text(label)
                    .font(.body.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(assetsToDelete.isEmpty ? Color(.systemGray4) : Color.deleteRed)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.deleteRed.opacity(assetsToDelete.isEmpty ? 0 : 0.4), radius: 8, y: 4)
        }
        .disabled(assetsToDelete.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.08), radius: 8, y: -4)
        )
    }
}

// MARK: - PhotoZoomView

enum PhotoZoomAction { case keep, remove }

struct PhotoZoomView: View {
    let assets: [PHAsset]
    let initialIndex: Int
    let keepIndices: Set<Int>
    let onToggle: (Int, PhotoZoomAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lm = LanguageManager.shared
    @State private var currentIndex: Int

    init(assets: [PHAsset], initialIndex: Int, keepIndices: Set<Int>, onToggle: @escaping (Int, PhotoZoomAction) -> Void) {
        self.assets = assets
        self.initialIndex = initialIndex
        self.keepIndices = keepIndices
        self.onToggle = onToggle
        _currentIndex = State(initialValue: initialIndex)
    }

    var isKept: Bool { keepIndices.contains(currentIndex) }
    var canRemove: Bool { true }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentIndex) {
                    ForEach(Array(assets.enumerated()), id: \.offset) { index, asset in
                        PhotoZoomPage(asset: asset)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                // ページインジケーター（上部）
                VStack {
                    Text("\(currentIndex + 1) / \(assets.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                    Spacer()

                    // 状態バッジ（下部）
                    HStack(spacing: 8) {
                        Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                        Text(isKept ? lm.keepPhoto : lm.deletePhoto)
                            .font(.subheadline.bold())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .foregroundStyle(isKept ? Color.keepGreen : Color.deleteRed)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(lm.close) { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isKept {
                        Button(lm.changeToDelete) {
                            if canRemove { onToggle(currentIndex, .remove) }
                        }
                        .foregroundStyle(canRemove ? Color.deleteRed : Color.gray)
                        .disabled(!canRemove)
                    } else {
                        Button(lm.changeToKeep) {
                            onToggle(currentIndex, .keep)
                        }
                        .bold()
                        .foregroundStyle(Color.keepGreen)
                    }
                }
            }
        }
    }
}

struct PhotoZoomPage: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            image = await PhotoLibraryManager.shared.loadImage(
                for: asset, targetSize: CGSize(width: 1200, height: 1200)
            )
        }
    }
}

// MARK: - PersonManagementView

struct PersonManagementView: View {
    @ObservedObject private var personRegistry = PersonRegistry.shared
    @ObservedObject private var lm = LanguageManager.shared
    @State private var showImagePicker = false
    @State private var showNameAlert = false
    @State private var pendingPhotoID: String? = nil
    @State private var newPersonName = ""

    var body: some View {
        List {
            if personRegistry.persons.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(lm.s("右上の＋から人物を追加できます", "Tap + to add a person"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .listRowBackground(Color.clear)
            } else {
                ForEach(personRegistry.persons) { person in
                    PersonRow(person: person)
                }
                .onDelete { offsets in
                    offsets.forEach { i in
                        personRegistry.deletePerson(id: personRegistry.persons[i].id)
                    }
                }
            }
        }
        .navigationTitle(lm.s("人物管理", "People"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerForPerson { assetID in
                pendingPhotoID = assetID
                showNameAlert = true
            }
        }
        .alert(lm.s("人物を追加", "Add Person"), isPresented: $showNameAlert) {
            TextField(lm.s("名前を入力", "Enter name"), text: $newPersonName)
            Button(lm.s("追加", "Add")) {
                let name = newPersonName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let person = personRegistry.addPerson(name: name)
                    if let pid = pendingPhotoID {
                        personRegistry.tagPhoto(assetID: pid, personID: person.id)
                    }
                }
                newPersonName = ""
                pendingPhotoID = nil
            }
            Button(lm.s("キャンセル", "Cancel"), role: .cancel) {
                newPersonName = ""
                pendingPhotoID = nil
            }
        } message: {
            if let pid = pendingPhotoID {
                Text(lm.s("選択した写真で人物を登録します", "This person will be linked to the selected photo"))
                    .font(.caption)
                let _ = pid // suppress warning
            }
        }
    }
}

// MARK: - PersonRow

struct PersonRow: View {
    let person: RegisteredPerson
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.systemGray5)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.body)
                Text("\(person.photoIDs.count) 枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard let firstID = person.photoIDs.first else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [firstID], options: nil)
        guard let asset = result.firstObject else { return }
        let size = CGSize(width: 96, height: 96)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // .opportunistic はハンドラを複数回（劣化版→最終版）呼ぶ。
            // サムネイルは届くたびに更新しつつ、継続は最終結果で1度だけ resume する
            // （複数回 resume するとクラッシュするため）。
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: opts) { img, info in
                if let img {
                    Task { @MainActor in thumbnail = img }
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
        }
    }
}

// MARK: - ImagePickerForPerson

struct ImagePickerForPerson: UIViewControllerRepresentable {
    let onPicked: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (String) -> Void
        init(onPicked: @escaping (String) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let id = results.first?.assetIdentifier else { return }
            onPicked(id)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @ObservedObject private var lm = LanguageManager.shared
    @StateObject private var tipStore = TipStore.shared

    var body: some View {
        NavigationStack {
            List {
                // 表示設定
                Section {
                    Toggle(isOn: $isDarkMode) {
                        Label(lm.darkMode, systemImage: "moon.fill")
                    }
                    .tint(Color.accent)

                    Picker(selection: $lm.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text("\(lang.flag) \(lang.displayName)").tag(lang)
                        }
                    } label: {
                        Label(lm.languageSetting, systemImage: "globe")
                    }
                } header: {
                    Text(lm.display)
                }

                // 人物フィルター
                Section {
                    NavigationLink {
                        PersonManagementView()
                    } label: {
                        Label(lm.s("人物管理", "People"), systemImage: "person.2.fill")
                    }
                } header: {
                    Text(lm.s("人物フィルター", "Person Filter"))
                }

                // AI選定基準
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        criteriaRow(icon: "camera.aperture", color: .blue,
                                    title: lm.criteriaSharpnessTitle, desc: lm.criteriaSharpnessDesc)
                        Divider()
                        criteriaRow(icon: "sun.max.fill", color: .orange,
                                    title: lm.criteriaExposureTitle, desc: lm.criteriaExposureDesc)
                        Divider()
                        criteriaRow(icon: "face.smiling", color: .pink,
                                    title: lm.criteriaFaceTitle, desc: lm.criteriaFaceDesc)
                        Divider()
                        criteriaRow(icon: "eye.fill", color: .green,
                                    title: lm.criteriaEyeTitle, desc: lm.criteriaEyeDesc)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(lm.aiCriteria)
                }

                // 注意事項
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        noteRow(icon: "exclamationmark.triangle.fill", color: .orange, text: lm.note1)
                        noteRow(icon: "icloud.slash",                  color: .blue,   text: lm.note2)
                        noteRow(icon: "trash.slash",                   color: .red,    text: lm.note3)
                        noteRow(icon: "person.2.fill",                 color: .purple, text: lm.note4)
                        noteRow(icon: "hand.raised.slash.fill",        color: .gray,   text: lm.note5)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(lm.notes)
                }

                // 開発者を応援
                Section {
                    TipJarSectionView(tipStore: tipStore)
                } header: {
                    Text(lm.tipJarTitle)
                }

                // クレジット
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        creditRow(title: lm.creditDeveloper, value: "YUDAIKUNZ")
                        Divider()
                        creditRow(title: lm.creditVersion,  value: "1.0.0")
                        Divider()
                        creditRow(title: lm.creditTech,     value: "Vision Framework\nCore ML\nSwiftUI")
                        Divider()
                        creditRow(title: lm.creditOS,       value: lm.isJapanese ? "iOS 16.0 以上" : "iOS 16.0+")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(lm.credits)
                }
            }
            .navigationTitle(lm.settings)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func criteriaRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func noteRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func creditRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - TipJarSectionView

struct TipJarSectionView: View {
    @ObservedObject var tipStore: TipStore
    @ObservedObject private var lm = LanguageManager.shared
    @State private var showingThanks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 説明文
            HStack(alignment: .top, spacing: 12) {
                Text("☕️")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(lm.tipJarDesc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 商品ロード中 / 取得失敗
            if tipStore.products.isEmpty {
                HStack {
                    Spacer()
                    if tipStore.isLoading || !tipStore.hasLoaded {
                        ProgressView()
                    } else {
                        Text(lm.s("現在ご利用いただけません", "Not available right now"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                // チップボタン
                HStack(spacing: 10) {
                    ForEach(tipStore.products) { product in
                        TipButton(product: product, tipStore: tipStore)
                    }
                }
            }

            // 購入中インジケーター
            if tipStore.purchaseState == .purchasing {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 4)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            if tipStore.products.isEmpty && !tipStore.hasLoaded && !tipStore.isLoading {
                Task { await tipStore.loadProducts() }
            }
        }
        .onChange(of: tipStore.purchaseState) { _, state in
            if state == .success { showingThanks = true }
        }
        .alert(lm.tipThanksTitle, isPresented: $showingThanks) {
            Button(lm.close, role: .cancel) {
                tipStore.purchaseState = .idle
            }
        } message: {
            Text(lm.tipThanksMessage)
        }
    }
}

struct TipButton: View {
    let product: Product
    @ObservedObject var tipStore: TipStore
    private var isPurchasing: Bool { tipStore.purchaseState == .purchasing }

    var body: some View {
        Button {
            Task { await tipStore.purchase(product) }
        } label: {
            VStack(spacing: 4) {
                Text(product.displayName)
                    .font(.caption.bold())
                Text(product.displayPrice)
                    .font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accent.opacity(0.12))
            .foregroundStyle(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accent.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }
}

// MARK: - PhotoActionsSheet

struct PhotoActionsSheet: View {
    let asset: PHAsset
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @ObservedObject private var personRegistry = PersonRegistry.shared
    @ObservedObject private var tagRegistry = TagRegistry.shared
    @EnvironmentObject private var lm: LanguageManager
    @State private var showAddPersonField = false
    @State private var newPersonName = ""
    @State private var showAddTagField = false
    @State private var newTagName = ""
    @State private var newTagColorIndex = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // お気に入り
                Section(lm.s("お気に入り", "Favorites")) {
                    let isFav = favoritesStore.isFavorite(asset.localIdentifier)
                    Button {
                        Task { await favoritesStore.toggle(asset: asset) }
                    } label: {
                        HStack {
                            Label(
                                isFav
                                    ? lm.s("お気に入り解除", "Remove from Favorites")
                                    : lm.s("お気に入りに追加", "Add to Favorites"),
                                systemImage: isFav ? "heart.fill" : "heart"
                            )
                            .foregroundStyle(isFav ? Color.pink : .primary)
                            Spacer()
                            if isFav {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.pink)
                                    .bold()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                // 人物タグ
                if !personRegistry.persons.isEmpty {
                    Section(lm.s("人物タグ", "Tag Person")) {
                        ForEach(personRegistry.persons) { person in
                            let isTagged = personRegistry.isTagged(
                                assetID: asset.localIdentifier,
                                personID: person.id
                            )
                            Button {
                                if isTagged {
                                    personRegistry.untagPhoto(assetID: asset.localIdentifier, personID: person.id)
                                } else {
                                    personRegistry.tagPhoto(assetID: asset.localIdentifier, personID: person.id)
                                }
                            } label: {
                                HStack {
                                    Label(person.name, systemImage: "person.fill")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if isTagged {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accent)
                                            .bold()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 人物新規登録
                Section {
                    if showAddPersonField {
                        HStack {
                            TextField(lm.s("名前を入力", "Enter name"), text: $newPersonName)
                            Button(lm.s("追加", "Add")) {
                                let name = newPersonName.trimmingCharacters(in: .whitespaces)
                                if !name.isEmpty {
                                    let person = personRegistry.addPerson(name: name)
                                    personRegistry.tagPhoto(assetID: asset.localIdentifier, personID: person.id)
                                }
                                newPersonName = ""
                                showAddPersonField = false
                            }
                            .disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        Button {
                            showAddPersonField = true
                        } label: {
                            Label(lm.s("新しい人物を登録", "Register New Person"), systemImage: "person.badge.plus")
                                .foregroundStyle(Color.accent)
                        }
                    }
                } header: {
                    Text(lm.s("人物登録", "Add Person"))
                }

                // タグ
                if !tagRegistry.tags.isEmpty {
                    Section(lm.s("タグ", "Tags")) {
                        ForEach(tagRegistry.tags) { tag in
                            let isTagged = tagRegistry.isTagged(
                                assetID: asset.localIdentifier,
                                tagID: tag.id
                            )
                            Button {
                                if isTagged {
                                    tagRegistry.untagPhoto(assetID: asset.localIdentifier, tagID: tag.id)
                                } else {
                                    tagRegistry.tagPhoto(assetID: asset.localIdentifier, tagID: tag.id)
                                }
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(Color.tagColor(tag.colorIndex))
                                        .frame(width: 10, height: 10)
                                    Text(tag.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if isTagged {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accent)
                                            .bold()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // タグ新規作成
                Section {
                    if showAddTagField {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField(lm.s("タグ名を入力", "Enter tag name"), text: $newTagName)
                            HStack(spacing: 8) {
                                Text(lm.s("色:", "Color:"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(0..<6, id: \.self) { i in
                                    Circle()
                                        .fill(Color.tagColor(i))
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary, lineWidth: newTagColorIndex == i ? 2 : 0)
                                        )
                                        .onTapGesture { newTagColorIndex = i }
                                }
                            }
                            Button(lm.s("作成", "Create")) {
                                let name = newTagName.trimmingCharacters(in: .whitespaces)
                                if !name.isEmpty {
                                    let tag = tagRegistry.addTag(name: name, colorIndex: newTagColorIndex)
                                    tagRegistry.tagPhoto(assetID: asset.localIdentifier, tagID: tag.id)
                                }
                                newTagName = ""
                                newTagColorIndex = 0
                                showAddTagField = false
                            }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .font(.body.bold())
                            .foregroundStyle(Color.accent)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            showAddTagField = true
                        } label: {
                            Label(lm.s("新しいタグを作成", "Create New Tag"), systemImage: "tag.fill")
                                .foregroundStyle(Color.accent)
                        }
                    }
                } header: {
                    Text(lm.s("タグ追加", "Add Tag"))
                }
            }
            .navigationTitle(lm.s("写真アクション", "Photo Actions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lm.s("完了", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - SliderSelector

struct SliderSelector: View {
    let label: String
    @Binding var value: Int
    let minVal: Int
    let maxVal: Int
    let displayText: () -> String

    @State private var sliderValue: Double = 0

    var minLabel: String { String(minVal) }
    var maxLabel: String { String(maxVal) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline) {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                Spacer()
                Text(displayText())
                    .font(.title2.bold())
                    .foregroundStyle(Color.accent)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.2), value: value)
                Spacer()
                Color.clear.frame(width: 36)
            }

            HStack(spacing: 8) {
                Text(minLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Slider(value: $sliderValue, in: Double(minVal)...Double(maxVal), step: 1)
                    .tint(Color.accent)
                    .onChange(of: sliderValue) { _, newVal in
                        let clamped = min(max(Int(newVal), minVal), maxVal)
                        if clamped != value { value = clamped }
                    }

                Text(maxLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { sliderValue = Double(value) }
        .onChange(of: value) { _, newVal in sliderValue = Double(newVal) }
        .onChange(of: maxVal) {
            if value > maxVal { value = maxVal }
        }
    }
}

// MARK: - AssetThumbnailView

struct AssetThumbnailView: View {
    let asset: PHAsset
    let size: CGSize
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .overlay(ProgressView())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task {
            image = await PhotoLibraryManager.shared.loadImage(for: asset, targetSize: size)
        }
    }
}

// MARK: - LibraryLoadingView

struct LibraryLoadingView: View {
    @ObservedObject private var lm = LanguageManager.shared
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.19, blue: 0.64),
                         Color(red: 0.39, green: 0.40, blue: 0.95)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)

                Text("Snap Sort")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.2)

                    Text(lm.s("写真を読み込み中", "Loading photos") + String(repeating: ".", count: dotCount + 1))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .animation(.none, value: dotCount)
                }
            }
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}

// MARK: - Supporting Views

struct PermissionRequestView: View {
    let action: () -> Void
    @ObservedObject private var lm = LanguageManager.shared

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accent.opacity(0.12))
                        .frame(width: 100, height: 100)
                    Image(systemName: "photo.badge.checkmark")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accent)
                }
                Text(lm.permissionTitle)
                    .font(.title3.bold())
                Text(lm.permissionDesc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(lm.permissionButton, action: action)
                .font(.body.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding()
    }
}

struct PermissionDeniedView: View {
    @ObservedObject private var lm = LanguageManager.shared

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.deleteRed.opacity(0.12))
                        .frame(width: 100, height: 100)
                    Image(systemName: "lock.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.deleteRed)
                }
                Text(lm.deniedTitle)
                    .font(.title3.bold())
                Text(lm.deniedDesc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(lm.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.body.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.deleteRed)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 32)
            Spacer()
        }
        .padding()
    }
}
