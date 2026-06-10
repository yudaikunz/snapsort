import SwiftUI
import Photos

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
                    HomeView(viewModel: viewModel)
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
                    Text("by YAZAWA")
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

// MARK: - HomeView

struct HomeView: View {
    @ObservedObject var viewModel: CuratorViewModel
    @ObservedObject private var library = PhotoLibraryManager.shared
    @EnvironmentObject private var lm: LanguageManager
    @State private var selectedRange: AnalysisRange = .all
    @State private var showingSettings = false
    @State private var selectedDate: Date = Date()
    @State private var selectedMonthYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedDay: Int = Calendar.current.component(.day, from: Date())

    private let currentYear = Calendar.current.component(.year, from: Date())
    private var yearRange: [Int] { Array((2000...currentYear).reversed()) }
    private let monthNames = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    var filteredAssets: [PHAsset] {
        let calendar = Calendar.current
        return library.allAssets.filter { asset in
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
                    .padding(.top, 8)
                }

                // 分析ボタン（下部固定）
                analyzeButton
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(Color.accent)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - Sub Views

    private var headerCard: some View {
        VStack(spacing: 16) {
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
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var maxDayInMonth: Int {
        let calendar = Calendar.current
        var components = DateComponents(year: selectedMonthYear, month: selectedMonth)
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
            Task { await viewModel.analyze(assets: filteredAssets) }
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

struct GroupDetailView: View {
    let group: PhotoGroup
    @ObservedObject var viewModel: CuratorViewModel
    @EnvironmentObject private var lm: LanguageManager
    @State private var keepIndices: Set<Int>
    @State private var showingDeleteConfirmation = false
    @State private var zoomedPhoto: ZoomedPhoto?
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
                        ForEach(score.recommendationReasons, id: \.self) { reason in
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
                    ZStack(alignment: .topTrailing) {
                        // 写真タップ → 拡大
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

                        // アイコンタップ → 切替
                        Button {
                            withAnimation(.spring(response: 0.2)) {
                                if isKept {
                                    keepIndices.remove(index)
                                } else {
                                    keepIndices.insert(index)
                                }
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

                        // AI推薦バッジ
                        if index == group.bestAssetIndex {
                            VStack {
                                Spacer()
                                Text(lm.aiPick)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.accent.opacity(0.9))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                    .padding(6)
                            }
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

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lm = LanguageManager.shared

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
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(lm.notes)
                }

                // クレジット
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        creditRow(title: lm.creditDeveloper, value: "YAZAWA")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lm.close) { dismiss() }
                }
            }
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
                    .onChange(of: sliderValue) { newVal in
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
        .onChange(of: value) { sliderValue = Double($0) }
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
