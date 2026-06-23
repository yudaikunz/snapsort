import SwiftUI
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import CoreLocation
import ImageIO

// MARK: - VideoURLTransferable (PhotosPicker 用)

struct VideoURLTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoURLTransferable(url: dest)
        }
    }
}

// MARK: - PHPickerWrapper (PHPickerViewController 直接利用)

struct PHPickerWrapper: UIViewControllerRepresentable {
    let onVideoURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PHPickerWrapper

        init(_ parent: PHPickerWrapper) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }

            let provider = result.itemProvider
            let types = [UTType.movie.identifier, UTType.video.identifier, "public.mpeg-4"]
            let typeID = types.first { provider.hasItemConformingToTypeIdentifier($0) } ?? UTType.movie.identifier

            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                guard let url else { return }
                let ext  = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + ext)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    DispatchQueue.main.async { self.parent.onVideoURL(dest) }
                } catch {
                    print("[PHPickerWrapper] copy failed: \(error)")
                }
            }
        }
    }
}

// MARK: - VideoFrameExtractorView

struct VideoFrameExtractorView: View {
    @ObservedObject private var lm      = LanguageManager.shared
    @ObservedObject private var library = PhotoLibraryManager.shared

    @State private var showPhotosPicker = false
    @State private var showFilePicker   = false
    @State private var isLoadingVideo   = false
    @State private var pickedAVAsset: AVAsset?
    @State private var navigateToPicked = false

    // 日付フィルター
    @State private var selectedRange: AnalysisRange = .all
    @State private var selectedYear: Int       = Calendar.current.component(.year,  from: Date())
    @State private var selectedMonth: Int      = Calendar.current.component(.month, from: Date())
    @State private var selectedDay: Int        = Calendar.current.component(.day,   from: Date())
    @State private var selectedMonthYear: Int  = Calendar.current.component(.year,  from: Date())

    private let currentYear = Calendar.current.component(.year, from: Date())
    private let monthNames  = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    private var maxDayInMonth: Int {
        let cal   = Calendar.current
        let comps = DateComponents(year: selectedMonthYear, month: selectedMonth)
        let date  = cal.date(from: comps) ?? Date()
        return cal.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    var filteredVideoAssets: [PHAsset] {
        let cal = Calendar.current
        return library.allVideoAssets.filter { asset in
            guard let date = asset.creationDate else { return selectedRange == .all }
            switch selectedRange {
            case .day:
                return cal.component(.year,  from: date) == selectedYear
                    && cal.component(.month, from: date) == selectedMonth
                    && cal.component(.day,   from: date) == selectedDay
            case .month:
                return cal.component(.year,  from: date) == selectedMonthYear
                    && cal.component(.month, from: date) == selectedMonth
            case .year:
                return cal.component(.year, from: date) == selectedYear
            case .all:
                return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard

                    if library.isLoadingVideos {
                        loadingCard
                    } else if library.allVideoAssets.isEmpty {
                        emptyCard
                    } else if filteredVideoAssets.isEmpty {
                        noResultsCard
                    } else {
                        videoGridContent
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPhotosPicker) {
                PHPickerWrapper { url in loadFromURL(url) }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let src = urls.first else { return }
                    guard src.startAccessingSecurityScopedResource() else { return }
                    let ext  = src.pathExtension.isEmpty ? "mov" : src.pathExtension
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + ext)
                    do {
                        try FileManager.default.copyItem(at: src, to: dest)
                        src.stopAccessingSecurityScopedResource()
                        loadFromURL(dest)
                    } catch {
                        src.stopAccessingSecurityScopedResource()
                    }
                case .failure: break
                }
            }
            .navigationDestination(isPresented: $navigateToPicked) {
                if let av = pickedAVAsset {
                    VideoFramePickerView(avAsset: av)
                }
            }
        }
        .task { await library.fetchAllVideos() }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text(lm.s("動画抽出", "Clip"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoadingVideo {
                    ProgressView().tint(Color.accent)
                } else {
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label(lm.s("写真ライブラリから選ぶ", "From Photo Library"),
                                  systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFilePicker = true
                        } label: {
                            Label(lm.s("ファイルから選ぶ", "From Files"),
                                  systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accent)
                            .font(.title3)
                    }
                }
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
                            .background(selectedRange == range ? Color.accent : Color.clear)
                            .foregroundStyle(selectedRange == range ? .white : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            videoDateSelectorView
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    @ViewBuilder
    private var videoDateSelectorView: some View {
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
                Image(systemName: "film")
                    .foregroundStyle(Color.accent)
                Text(lm.s("すべての動画 \(library.allVideoAssets.count)本",
                           "All videos: \(library.allVideoAssets.count)"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Content Cards

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2).tint(Color.accent)
            Text(lm.s("動画を読み込み中…", "Loading videos…"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var emptyCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.slash")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(lm.s("動画がありません", "No videos found"))
                    .font(.headline)
                Text(lm.s("右上の ＋ から動画を選んでください", "Tap + to select a video"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var noResultsCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(lm.s("該当する動画がありません", "No videos found"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var videoGridContent: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
            spacing: 12
        ) {
            ForEach(filteredVideoAssets, id: \.localIdentifier) { asset in
                NavigationLink(destination: VideoFramePickerView(asset: asset)) {
                    VideoThumbnailCard(asset: asset)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func loadFromURL(_ url: URL) {
        isLoadingVideo = true
        Task {
            let av = AVURLAsset(url: url)
            _ = try? await av.load(.isPlayable, .duration)
            await MainActor.run {
                pickedAVAsset    = av
                navigateToPicked = true
                isLoadingVideo   = false
            }
        }
    }
}

// MARK: - VideoThumbnailCard

struct VideoThumbnailCard: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color(.systemGray5)).overlay(ProgressView())
                }
            }
            .frame(height: 120).clipped()

            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .offset(x: 1.5)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(durationString)
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .task {
            thumbnail = await PhotoLibraryManager.shared.loadImage(
                for: asset, targetSize: CGSize(width: 320, height: 240)
            )
        }
    }

    private var durationString: String {
        let d = Int(asset.duration)
        return String(format: "%d:%02d", d / 60, d % 60)
    }
}

// MARK: - VideoFramePickerView

struct VideoFramePickerView: View {
    @ObservedObject private var lm = LanguageManager.shared

    private let phAsset: PHAsset?
    private let preloadedAVAsset: AVAsset?
    @State private var assetDuration: Double

    init(asset: PHAsset) {
        phAsset = asset; preloadedAVAsset = nil
        _assetDuration = State(initialValue: asset.duration)
    }

    init(avAsset: AVAsset) {
        phAsset = nil; preloadedAVAsset = avAsset
        _assetDuration = State(initialValue: 0)
    }

    @State private var avAsset: AVAsset?
    @State private var frameImage: UIImage?
    @State private var frameGenTask: Task<Void, Never>?
    @State private var frameTime: Double = 0
    @State private var isLoadingVideo = true
    @State private var isSaving       = false
    @State private var showSavedAlert = false
    @State private var bestShots:    [BestShotCandidate] = []
    @State private var isAnalyzing   = false
    @State private var analysisTask: Task<Void, Never>?

    // 動画から引き継ぐメタデータ
    @State private var videoCreationDate: Date?     = nil
    @State private var videoLocation: CLLocation?   = nil
    @State private var videoMake: String?            = nil   // 撮影デバイスメーカー
    @State private var videoModel: String?           = nil   // 撮影デバイスモデル
    @State private var videoSoftware: String?        = nil   // ソフトウェア（iOS バージョン）

    private var duration: Double { max(assetDuration, 0.001) }
    private var canSave: Bool    { avAsset != nil && !isSaving && !isLoadingVideo }

    private var navTitle: String {
        if let date = videoCreationDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "M月d日"
            fmt.locale = Locale(identifier: "ja_JP")
            return fmt.string(from: date)
        }
        return lm.s("フレーム抽出", "Frame Picker")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 20) {
                    framePreviewCard
                    if isAnalyzing || !bestShots.isEmpty {
                        bestShotsCard
                    }
                    scrubberCard
                    // 動画メタデータ情報カード
                    if videoCreationDate != nil || videoLocation != nil
                        || videoModel != nil || videoSoftware != nil {
                        metadataInfoCard
                    }
                    Color.clear.frame(height: 80)
                }
                .padding()
            }
            saveButton
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(navTitle)
        .task { await loadVideo() }
        .onDisappear {
            analysisTask?.cancel()
            frameGenTask?.cancel()
        }
        .alert(lm.s("保存しました", "Saved"), isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(savedAlertMessage)
        }
    }

    // MARK: - Metadata Info Card

    private var metadataInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(lm.s("動画の情報", "Video Info"), systemImage: "info.circle")
                .font(.subheadline.bold())
                .foregroundStyle(Color.accent)

            if let date = videoCreationDate {
                let locale = Locale(identifier: lm.isJapanese ? "ja_JP" : "en_US")
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lm.s("撮影日時（保存時に引き継ぎ）", "Date/time (will be inherited)"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(date.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
                            .font(.subheadline)
                    }
                }
            }

            if let loc = videoLocation {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lm.s("位置情報（保存時に引き継ぎ）", "Location (will be inherited)"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.4f, %.4f",
                                    loc.coordinate.latitude,
                                    loc.coordinate.longitude))
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }

            if let model = videoModel {
                let deviceStr = [videoMake, model].compactMap { $0 }.joined(separator: " ")
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lm.s("撮影デバイス（EXIF に埋め込み）", "Device (embedded in EXIF)"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(deviceStr).font(.subheadline)
                    }
                }
            }

            if let sw = videoSoftware {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lm.s("ソフトウェア（EXIF に埋め込み）", "Software (embedded in EXIF)"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(sw).font(.subheadline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    // MARK: - Frame Preview Card

    private var framePreviewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.black)
                .aspectRatio(16 / 9, contentMode: .fit)

            if let img = frameImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if isLoadingVideo {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "film").font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    // MARK: - Best Shots Card

    private var bestShotsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(lm.s("ベストショット候補", "Best Shots"), systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accent)
                Spacer()
                if isAnalyzing {
                    ProgressView().scaleEffect(0.75).tint(Color.accent)
                }
            }

            if bestShots.isEmpty {
                Text(lm.s("分析中…", "Analyzing…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(bestShots) { shot in
                            Button {
                                frameTime = shot.timeSeconds
                            } label: {
                                shotThumb(shot)
                            }
                            .buttonStyle(.plain)
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

    private func shotThumb(_ shot: BestShotCandidate) -> some View {
        let selected = abs(frameTime - shot.timeSeconds) < 0.15
        return VStack(spacing: 4) {
            Image(uiImage: shot.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 54)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accent : Color.clear, lineWidth: 2)
                )
            Text(timeString(shot.timeSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(selected ? Color.accent : .secondary)
        }
    }

    // MARK: - Scrubber Card

    private var scrubberCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(lm.s("フレーム位置", "Frame Position"), systemImage: "slider.horizontal.below.rectangle")
                    .font(.subheadline.bold())
                Spacer()
                Text(timeString(frameTime))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.accent)
            }
            Slider(value: $frameTime, in: 0...(duration - 0.001))
                .tint(Color.accent)
                .onChange(of: frameTime) { _, t in scheduleFrameGeneration(at: t) }
            HStack {
                Text("0:00").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(timeString(duration)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var saveButton: some View {
        Button {
            Task { await saveFrame() }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.down.fill").font(.body.bold())
                    Text(lm.s("写真として保存", "Save as Photo")).font(.body.bold())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canSave ? Color.accent : Color(.systemGray4))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.accent.opacity(canSave ? 0.4 : 0), radius: 8, y: 4)
        }
        .disabled(!canSave)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.08), radius: 8, y: -4)
        )
    }

    // MARK: - Video Loading

    private func loadVideo() async {
        if let preloaded = preloadedAVAsset {
            avAsset = preloaded
            if let dur = try? await preloaded.load(.duration) {
                assetDuration = dur.seconds
            }
            isLoadingVideo = false
            await loadAVMetadata(from: preloaded)
            scheduleFrameGeneration(at: 0)
            startAnalysis()
        } else if let ph = phAsset {
            isLoadingVideo = true
            let av = await PhotoLibraryManager.shared.loadAVAsset(for: ph)
            avAsset = av
            isLoadingVideo = false
            // PHAsset から直接取得（最も確実）
            videoCreationDate = ph.creationDate
            videoLocation     = ph.location
            // AVAsset からも補完を試みる
            if let av, videoLocation == nil {
                await loadAVMetadata(from: av)
            }
            scheduleFrameGeneration(at: 0)
            startAnalysis()
        }
    }

    /// AVAsset のメタデータから日時・位置情報を抽出する
    private func loadAVMetadata(from asset: AVAsset) async {
        guard let items = try? await asset.load(.metadata) else { return }

        // 作成日時
        if videoCreationDate == nil {
            let dateItems = AVMetadataItem.metadataItems(
                from: items, filteredByIdentifier: .commonIdentifierCreationDate)
            if let item = dateItems.first {
                if let date = try? await item.load(.value) as? Date {
                    videoCreationDate = date
                } else if let str = try? await item.load(.stringValue) {
                    let f1 = ISO8601DateFormatter()
                    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    videoCreationDate = f1.date(from: str) ?? ISO8601DateFormatter().date(from: str)
                }
            }
        }

        // 位置情報 (ISO 6709 形式: "+35.6894+139.6917+040/" など)
        if videoLocation == nil {
            let locItems = AVMetadataItem.metadataItems(
                from: items, filteredByIdentifier: .commonIdentifierLocation)
            if let item = locItems.first,
               let locStr = try? await item.load(.stringValue) {
                videoLocation = parseISO6709(locStr)
            }
        }

        // Make（メーカー）
        if videoMake == nil {
            let makeItems = AVMetadataItem.metadataItems(
                from: items, filteredByIdentifier: .commonIdentifierMake)
            if let item = makeItems.first,
               let str = try? await item.load(.stringValue), !str.isEmpty {
                videoMake = str
            }
        }

        // Model（モデル名）
        if videoModel == nil {
            let modelItems = AVMetadataItem.metadataItems(
                from: items, filteredByIdentifier: .commonIdentifierModel)
            if let item = modelItems.first,
               let str = try? await item.load(.stringValue), !str.isEmpty {
                videoModel = str
            }
        }

        // Software（iOS バージョンなど）
        if videoSoftware == nil {
            let swItems = AVMetadataItem.metadataItems(
                from: items, filteredByIdentifier: .commonIdentifierSoftware)
            if let item = swItems.first,
               let str = try? await item.load(.stringValue), !str.isEmpty {
                videoSoftware = str
            }
        }

        // QuickTime 固有メタデータからも補完
        let qtItems = try? await asset.loadMetadata(for: .quickTimeMetadata)
        if let qtItems {
            if videoMake == nil {
                let v = AVMetadataItem.metadataItems(
                    from: qtItems, filteredByIdentifier: .quickTimeMetadataMake).first
                if let s = try? await v?.load(.stringValue), !s.isEmpty { videoMake = s }
            }
            if videoModel == nil {
                let v = AVMetadataItem.metadataItems(
                    from: qtItems, filteredByIdentifier: .quickTimeMetadataModel).first
                if let s = try? await v?.load(.stringValue), !s.isEmpty { videoModel = s }
            }
            if videoSoftware == nil {
                let v = AVMetadataItem.metadataItems(
                    from: qtItems, filteredByIdentifier: .quickTimeMetadataSoftware).first
                if let s = try? await v?.load(.stringValue), !s.isEmpty { videoSoftware = s }
            }
        }
    }

    /// ISO 6709 文字列を CLLocation に変換する
    private func parseISO6709(_ str: String) -> CLLocation? {
        guard let regex = try? NSRegularExpression(pattern: #"([+\-]\d+\.?\d*)"#) else { return nil }
        let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
        let values = matches.compactMap { m -> Double? in
            guard let r = Range(m.range, in: str) else { return nil }
            return Double(str[r])
        }
        guard values.count >= 2 else { return nil }
        let lat = values[0], lon = values[1]
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    // MARK: - Frame Generation

    private func scheduleFrameGeneration(at time: Double) {
        frameGenTask?.cancel()
        frameGenTask = Task { await generateFrame(at: time) }
    }

    private func generateFrame(at time: Double) async {
        guard let av = avAsset, !Task.isCancelled else { return }
        let generator = AVAssetImageGenerator(asset: av)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cmTime = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: cmTime),
              !Task.isCancelled else { return }
        frameImage = UIImage(cgImage: cgImage)
    }

    // MARK: - Analysis

    private func startAnalysis() {
        guard let av = avAsset else { return }
        analysisTask?.cancel()
        isAnalyzing = true
        bestShots   = []
        analysisTask = Task {
            let shots = await VideoAnalyzer.shared.findBestShots(asset: av, count: 5)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                bestShots   = shots
                isAnalyzing = false
            }
        }
    }

    // MARK: - Save

    /// 動画のフレームを写真として保存する（EXIF/GPS/TIFF メタデータを完全に引き継ぐ）
    private func saveFrame() async {
        guard let av = avAsset else { return }
        isSaving = true; defer { isSaving = false }
        do {
            // フレームを最大解像度で生成
            let generator = AVAssetImageGenerator(asset: av)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = .zero          // ネイティブ解像度
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter  = .zero
            let cmTime = CMTime(seconds: max(frameTime, 0), preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: cmTime)

            // フレーム時刻を加算した日時（動画開始 + フレームオフセット）
            let frameDate = videoCreationDate.map { $0.addingTimeInterval(frameTime) }

            // EXIF/GPS/TIFF メタデータを JPEG に埋め込む
            let metadata = buildEXIFMetadata(
                date: frameDate,
                location: videoLocation,
                make: videoMake,
                model: videoModel,
                software: videoSoftware
            )

            if let jpegData = embedMetadataInJPEG(cgImage: cgImage, metadata: metadata) {
                // メタデータ付き JPEG として保存
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    let opts = PHAssetResourceCreationOptions()
                    opts.uniformTypeIdentifier = UTType.jpeg.identifier
                    req.addResource(with: .photo, data: jpegData, options: opts)
                    if let date = frameDate    { req.creationDate = date }
                    if let loc  = videoLocation { req.location = loc }
                }
            } else {
                // フォールバック: UIImage で保存
                let image = UIImage(cgImage: cgImage)
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.creationRequestForAsset(from: image)
                    if let date = frameDate    { req.creationDate = date }
                    if let loc  = videoLocation { req.location = loc }
                }
            }
            showSavedAlert = true
        } catch {}
    }

    // MARK: - EXIF Helpers

    /// EXIF / GPS / TIFF メタデータ辞書を構築する
    private func buildEXIFMetadata(
        date: Date?,
        location: CLLocation?,
        make: String?,
        model: String?,
        software: String?
    ) -> [String: Any] {
        var props: [String: Any] = [:]

        // ── TIFF ──────────────────────────────────────────────
        var tiff: [String: Any] = [:]
        if let make    { tiff[kCGImagePropertyTIFFMake     as String] = make }
        if let model   { tiff[kCGImagePropertyTIFFModel    as String] = model }
        if let software { tiff[kCGImagePropertyTIFFSoftware as String] = software }
        if let date {
            tiff[kCGImagePropertyTIFFDateTime as String] = exifDateString(date, utc: false)
        }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary as String] = tiff }

        // ── EXIF ──────────────────────────────────────────────
        var exif: [String: Any] = [:]
        if let date {
            let s = exifDateString(date, utc: false)
            exif[kCGImagePropertyExifDateTimeOriginal  as String] = s
            exif[kCGImagePropertyExifDateTimeDigitized as String] = s
        }
        if let make  { exif[kCGImagePropertyExifLensMake  as String] = make  }
        if let model { exif[kCGImagePropertyExifLensModel as String] = model }
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary as String] = exif }

        // ── GPS ───────────────────────────────────────────────
        if let loc = location {
            var gps: [String: Any] = [:]
            let lat = loc.coordinate.latitude
            let lon = loc.coordinate.longitude
            gps[kCGImagePropertyGPSLatitude     as String] = abs(lat)
            gps[kCGImagePropertyGPSLatitudeRef  as String] = lat >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitude    as String] = abs(lon)
            gps[kCGImagePropertyGPSLongitudeRef as String] = lon >= 0 ? "E" : "W"
            if loc.altitude != 0 {
                gps[kCGImagePropertyGPSAltitude    as String] = abs(loc.altitude)
                gps[kCGImagePropertyGPSAltitudeRef as String] = loc.altitude < 0 ? 1 : 0
            }
            if let date {
                gps[kCGImagePropertyGPSDateStamp  as String] = exifDateString(date, utc: true, dateOnly: true)
                gps[kCGImagePropertyGPSTimeStamp  as String] = exifDateString(date, utc: true, timeOnly: true)
            }
            props[kCGImagePropertyGPSDictionary as String] = gps
        }

        return props
    }

    /// CGImage + メタデータ辞書 → JPEG Data
    private func embedMetadataInJPEG(cgImage: CGImage, metadata: [String: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        var imgProps = metadata
        imgProps[kCGImageDestinationLossyCompressionQuality as String] = 0.92
        CGImageDestinationAddImage(dest, cgImage, imgProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// EXIF 形式の日時文字列を生成する
    private func exifDateString(
        _ date: Date,
        utc: Bool,
        dateOnly: Bool = false,
        timeOnly: Bool = false
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utc ? TimeZone(identifier: "UTC") : TimeZone.current
        if dateOnly      { fmt.dateFormat = "yyyy:MM:dd" }
        else if timeOnly { fmt.dateFormat = "HH:mm:ss" }
        else             { fmt.dateFormat = "yyyy:MM:dd HH:mm:ss" }
        return fmt.string(from: date)
    }

    // MARK: - Helpers

    private var savedAlertMessage: String {
        var meta: [String] = []
        if videoCreationDate != nil { meta.append(lm.s("日時", "date")) }
        if videoLocation     != nil { meta.append(lm.s("GPS", "GPS")) }
        if videoModel        != nil { meta.append(lm.s("デバイス情報", "device info")) }
        if videoSoftware     != nil { meta.append(lm.s("ソフトウェア", "software")) }
        if meta.isEmpty {
            return lm.s("フレームを写真として保存しました", "Frame saved as photo")
        }
        return lm.s(
            "EXIF付きで保存しました（\(meta.joined(separator: "・"))）",
            "Saved with EXIF: \(meta.joined(separator: ", "))"
        )
    }

    private func timeString(_ t: Double) -> String {
        let total = Int(max(t, 0))
        let frac  = Int((t - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, frac)
    }
}
