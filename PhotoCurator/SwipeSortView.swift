import SwiftUI
import Photos

// MARK: - SwipeSortView
//
// グループ横断のカードデッキ。1グループを消化すると次グループへ自動で進む。
// 左=削除 / 右=残す / 上=お気に入り（残す扱い）。
// 全カードを判定後にサマリーを表示し、まとめて削除を確認してから適用する。

struct SwipeCard: Identifiable {
    let id: String          // "<groupIndex>-<localIdentifier>"
    let asset: PHAsset
    let groupIndex: Int
    let isBest: Bool
    let indexInGroup: Int
    let groupSize: Int
}

struct SwipeSortView: View {
    @ObservedObject var viewModel: CuratorViewModel
    @ObservedObject private var lm = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var deck: [SwipeCard] = []
    @State private var index = 0
    @State private var decisions: [String: SwipeDecision] = [:]
    @State private var drag: CGSize = .zero
    @State private var isApplying = false
    @State private var zoomItem: ZoomItem?      // フルスクリーン拡大（閲覧のみ）
    @State private var showOverview = false      // グループ一覧（選び直し）
    // カード上でのその場ズーム
    @State private var cardScale: CGFloat = 1
    @State private var cardLastScale: CGFloat = 1
    @State private var cardPan: CGSize = .zero
    @State private var cardLastPan: CGSize = .zero

    private let hThreshold: CGFloat = 100
    private let vThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if deck.isEmpty {
                ProgressView()
            } else if index >= deck.count {
                summaryView
            } else {
                VStack(spacing: 14) {
                    header
                    cardStack
                    actionButtons
                    hintRow
                }
                .padding()
            }

            if isApplying {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView().scaleEffect(1.3).tint(.white)
            }
        }
        .onAppear(perform: buildDeck)
        .fullScreenCover(item: $zoomItem) { item in
            ZoomableImageView(asset: item.asset, decision: nil, lm: lm,
                              onSet: nil, onClose: { zoomItem = nil })
        }
        .sheet(isPresented: $showOverview) {
            if let gi = current?.groupIndex, viewModel.groups.indices.contains(gi) {
                let group = viewModel.groups[gi]
                GroupOverviewSheet(
                    assets: group.assets,
                    bestID: group.assets[group.bestAssetIndex].localIdentifier,
                    decisions: decisions,
                    lm: lm,
                    setDecision: { id, d in decisions[id] = d },
                    onClose: { showOverview = false }
                )
            }
        }
    }

    // MARK: Deck

    private func buildDeck() {
        guard deck.isEmpty else { return }
        var cards: [SwipeCard] = []
        for (gi, group) in viewModel.groups.enumerated() {
            guard group.assets.indices.contains(group.bestAssetIndex) else { continue }
            let best = group.assets[group.bestAssetIndex]
            // ベスト写真を先頭に、その後に残りを元の順で
            var ordered = [best]
            ordered += group.assets.enumerated()
                .filter { $0.offset != group.bestAssetIndex }
                .map { $0.element }
            for (j, asset) in ordered.enumerated() {
                cards.append(SwipeCard(
                    id: "\(gi)-\(asset.localIdentifier)",
                    asset: asset,
                    groupIndex: gi,
                    isBest: asset.localIdentifier == best.localIdentifier,
                    indexInGroup: j,
                    groupSize: group.assets.count
                ))
            }
        }
        deck = cards
    }

    private var current: SwipeCard? { index < deck.count ? deck[index] : nil }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if let c = current {
                VStack(spacing: 2) {
                    Text(lm.s("グループ \(c.groupIndex + 1) / \(viewModel.groups.count)",
                              "Group \(c.groupIndex + 1) / \(viewModel.groups.count)"))
                        .font(.subheadline.bold())
                    Text(lm.s("写真 \(c.indexInGroup + 1) / \(c.groupSize)",
                              "Photo \(c.indexInGroup + 1) / \(c.groupSize)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button { showOverview = true } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.body.bold())
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)

                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.body.bold())
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.4 : 1)
            }
        }
    }

    // MARK: Card stack

    private var cardStack: some View {
        ZStack {
            // 背景カード（次の1枚）。固有IDで identity を固定し、
            // 手前に繰り上がったときに読み込み済み画像をそのまま再利用する。
            if index + 1 < deck.count {
                cardFace(deck[index + 1])
                    .scaleEffect(0.94)
                    .offset(y: 12)
                    .id(deck[index + 1].id)
            }
            // 手前のカード
            if let c = current {
                cardFace(c, scale: cardScale, pan: cardPan)
                    .id(c.id)
                    .overlay(borderHighlight)
                    .overlay(decisionBadge)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            resetCardZoom()
                            zoomItem = ZoomItem(id: c.asset.localIdentifier, asset: c.asset)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.35), in: Circle())
                                .padding(12)
                        }
                        .buttonStyle(.plain)
                    }
                    .offset(x: drag.width, y: drag.height)
                    .rotationEffect(.degrees(Double(drag.width / 18)))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if cardScale > 1.01 {
                                    cardPan = CGSize(width: cardLastPan.width + value.translation.width,
                                                     height: cardLastPan.height + value.translation.height)
                                } else {
                                    drag = value.translation
                                }
                            }
                            .onEnded { value in
                                if cardScale > 1.01 {
                                    cardLastPan = cardPan
                                } else {
                                    onDragEnded(value.translation)
                                }
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                cardScale = min(max(cardLastScale * value, 1), 4)
                            }
                            .onEnded { _ in
                                cardLastScale = cardScale
                                if cardScale <= 1.01 { resetCardZoom() }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3)) {
                            if cardScale > 1.01 { resetCardZoom() }
                            else { cardScale = 2.5; cardLastScale = 2.5 }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func cardFace(_ card: SwipeCard, scale: CGFloat = 1, pan: CGSize = .zero) -> some View {
        SwipeCardImage(asset: card.asset, zoomScale: scale, zoomPan: pan)
            .aspectRatio(3.0/4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topLeading) {
                if card.isBest {
                    Label(lm.s("AI推薦", "AI Pick"), systemImage: "sparkles")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(Color.accent)
                        .padding(12)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// ドラッグの向きから判定方向を求める（しきい値手前から表示）
    private var dragDecision: SwipeDecision? {
        if drag.height < -40 && abs(drag.height) > abs(drag.width) { return .favorite }
        if drag.width > 40 { return .keep }
        if drag.width < -40 { return .delete }
        return nil
    }

    /// 判定方向に対する進捗（0〜1）。しきい値に近づくほど 1。
    private var dragProgress: Double {
        switch dragDecision {
        case .keep, .delete: return Double(min(1, abs(drag.width) / hThreshold))
        case .favorite:      return Double(min(1, abs(drag.height) / vThreshold))
        case .none:          return 0
        }
    }

    private func badgeStyle(for d: SwipeDecision)
        -> (text: String, icon: String, color: Color, alignment: Alignment) {
        switch d {
        case .keep:     return (lm.s("残す", "KEEP"), "checkmark", Color.keepGreen, .topLeading)
        case .delete:   return (lm.s("削除", "DELETE"), "trash", Color.deleteRed, .topTrailing)
        case .favorite: return (lm.s("お気に入り", "FAVORITE"), "star.fill", .orange, .top)
        }
    }

    /// スワイプ方向に応じた、はっきりした色付きバッジ（1つだけ表示）
    @ViewBuilder private var decisionBadge: some View {
        if let d = dragDecision {
            let style = badgeStyle(for: d)
            Label(style.text, systemImage: style.icon)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(style.color, in: Capsule())
                .shadow(color: style.color.opacity(0.4), radius: 8, y: 2)
                .opacity(min(1, dragProgress * 1.6))
                .scaleEffect(0.85 + 0.15 * dragProgress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.alignment)
                .padding(24)
                .allowsHitTesting(false)
        }
    }

    /// スワイプ方向の色でカード枠をハイライト
    @ViewBuilder private var borderHighlight: some View {
        if let d = dragDecision {
            RoundedRectangle(cornerRadius: 18)
                .stroke(badgeStyle(for: d).color, lineWidth: 4)
                .opacity(dragProgress)
                .allowsHitTesting(false)
        }
    }

    // MARK: Buttons & hints

    private var actionButtons: some View {
        HStack(spacing: 20) {
            circleButton(icon: "trash", color: Color.deleteRed, size: 56) { commit(.delete) }
            circleButton(icon: "star", color: .orange, size: 48) { commit(.favorite) }
            circleButton(icon: "checkmark", color: Color.keepGreen, size: 56) { commit(.keep) }
        }
    }

    private func circleButton(icon: String, color: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(Color(.secondarySystemBackground), in: Circle())
                .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var hintRow: some View {
        HStack {
            Label(lm.s("削除", "Delete"), systemImage: "arrow.left")
            Spacer()
            Label(lm.s("お気に入り", "Favorite"), systemImage: "arrow.up")
            Spacer()
            Label(lm.s("残す", "Keep"), systemImage: "arrow.right")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    // MARK: Summary

    private var summaryView: some View {
        let del = decisions.values.filter { $0 == .delete }.count
        let keep = decisions.values.filter { $0 == .keep }.count
        let fav = decisions.values.filter { $0 == .favorite }.count
        return VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.keepGreen)
            Text(lm.s("整理が完了しました", "Review Complete"))
                .font(.title2.bold())

            VStack(spacing: 12) {
                summaryRow(icon: "trash", color: Color.deleteRed, label: lm.s("削除", "Delete"), value: del)
                summaryRow(icon: "checkmark", color: Color.keepGreen, label: lm.s("残す", "Keep"), value: keep)
                summaryRow(icon: "star.fill", color: .orange, label: lm.s("お気に入り", "Favorite"), value: fav)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 12) {
                Button {
                    Task { await apply() }
                } label: {
                    Text(del > 0
                         ? lm.s("\(del)枚を削除する", "Delete \(del) photos")
                         : lm.s("完了", "Done"))
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(del > 0 ? Color.deleteRed : Color.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button(lm.s("やり直す", "Start Over")) {
                    decisions = [:]; index = 0; drag = .zero
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private func summaryRow(icon: String, color: Color, label: String, value: Int) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            Text(label)
            Spacer()
            Text("\(value)").font(.body.bold())
        }
        .frame(width: 220)
    }

    // MARK: Actions

    private func onDragEnded(_ t: CGSize) {
        if t.height < -vThreshold && abs(t.width) < hThreshold {
            commit(.favorite, exit: CGSize(width: t.width, height: -900))
        } else if t.width > hThreshold {
            commit(.keep, exit: CGSize(width: 700, height: t.height))
        } else if t.width < -hThreshold {
            commit(.delete, exit: CGSize(width: -700, height: t.height))
        } else {
            withAnimation(.spring(response: 0.3)) { drag = .zero }
        }
    }

    private func commit(_ decision: SwipeDecision, exit: CGSize? = nil) {
        guard let card = current else { return }
        decisions[card.asset.localIdentifier] = decision
        let target = exit ?? defaultExit(for: decision)
        withAnimation(.easeOut(duration: 0.22)) { drag = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            index += 1
            drag = .zero
            resetCardZoom()
        }
    }

    private func resetCardZoom() {
        cardScale = 1; cardLastScale = 1; cardPan = .zero; cardLastPan = .zero
    }

    private func defaultExit(for decision: SwipeDecision) -> CGSize {
        switch decision {
        case .keep:     return CGSize(width: 700, height: 0)
        case .delete:   return CGSize(width: -700, height: 0)
        case .favorite: return CGSize(width: 0, height: -900)
        }
    }

    private func undo() {
        guard index > 0 else { return }
        index -= 1
        decisions[deck[index].asset.localIdentifier] = nil
        drag = .zero
        resetCardZoom()
    }

    private func apply() async {
        isApplying = true
        await viewModel.applySwipeDecisions(decisions)
        isApplying = false
        dismiss()
    }
}

// MARK: - SwipeCardImage

private struct SwipeCardImage: View {
    let asset: PHAsset
    var zoomScale: CGFloat = 1
    var zoomPan: CGSize = .zero
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    // 写真全体が見えるよう fit 表示。ズーム時はスケール＋パン。
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoomScale)
                        .offset(zoomPan)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: asset.localIdentifier) {
            image = nil
            image = await PhotoLibraryManager.shared.loadImage(
                for: asset, targetSize: CGSize(width: 1600, height: 1600))
        }
    }
}

// MARK: - ZoomItem

struct ZoomItem: Identifiable {
    let id: String          // asset.localIdentifier
    let asset: PHAsset
}

// MARK: - ZoomableImageView
//
// 写真をフルスクリーンで拡大表示。ピンチ／ダブルタップでズーム。
// onSet を渡すと下部に判定ボタン（削除／お気に入り／残す）を表示する。

struct ZoomableImageView: View {
    let asset: PHAsset
    let decision: SwipeDecision?
    let lm: LanguageManager
    var onSet: ((SwipeDecision) -> Void)?
    var onClose: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * pinch)
                    .offset(x: offset.width + dragTranslation.width,
                            y: offset.height + dragTranslation.height)
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = min(max(scale * value, 1), 5)
                                if scale == 1 { offset = .zero }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .updating($dragTranslation) { value, state, _ in
                                if scale > 1 { state = value.translation }
                            }
                            .onEnded { value in
                                if scale > 1 {
                                    offset.width += value.translation.width
                                    offset.height += value.translation.height
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3)) {
                            if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                Spacer()
                if onSet != nil {
                    HStack(spacing: 28) {
                        zoomDecisionButton(.delete, "trash", Color.deleteRed)
                        zoomDecisionButton(.favorite, "star.fill", .orange)
                        zoomDecisionButton(.keep, "checkmark", Color.keepGreen)
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding()
        }
        .task(id: asset.localIdentifier) {
            image = await PhotoLibraryManager.shared.loadImage(
                for: asset, targetSize: CGSize(width: 2200, height: 2200))
        }
    }

    private func zoomDecisionButton(_ d: SwipeDecision, _ icon: String, _ color: Color) -> some View {
        Button { onSet?(d) } label: {
            Image(systemName: icon)
                .font(.title2.bold())
                .foregroundStyle(decision == d ? .white : color)
                .frame(width: 58, height: 58)
                .background(decision == d ? color : Color.white.opacity(0.18), in: Circle())
                .overlay(Circle().stroke(color, lineWidth: decision == d ? 0 : 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - GroupOverviewSheet
//
// 現在のグループの写真を一覧表示。各写真に現在の判定バッジと AI推薦 を表示し、
// タップで拡大＋判定の変更（選び直し）ができる。

struct GroupOverviewSheet: View {
    let assets: [PHAsset]
    let bestID: String
    let decisions: [String: SwipeDecision]
    let lm: LanguageManager
    var setDecision: (String, SwipeDecision) -> Void
    var onClose: () -> Void

    @State private var zoomItem: ZoomItem?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        Button {
                            zoomItem = ZoomItem(id: asset.localIdentifier, asset: asset)
                        } label: {
                            OverviewThumb(
                                asset: asset,
                                isBest: asset.localIdentifier == bestID,
                                decision: decisions[asset.localIdentifier]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(lm.s("グループ一覧", "Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lm.s("完了", "Done"), action: onClose)
                }
            }
            .fullScreenCover(item: $zoomItem) { item in
                ZoomableImageView(
                    asset: item.asset,
                    decision: decisions[item.id],
                    lm: lm,
                    onSet: { d in setDecision(item.id, d); zoomItem = nil },
                    onClose: { zoomItem = nil }
                )
            }
        }
    }
}

// MARK: - OverviewThumb

private struct OverviewThumb: View {
    let asset: PHAsset
    let isBest: Bool
    let decision: SwipeDecision?
    @State private var image: UIImage?

    private var decisionColor: Color {
        switch decision {
        case .keep:     return Color.keepGreen
        case .delete:   return Color.deleteRed
        case .favorite: return .orange
        case .none:     return .clear
        }
    }

    private var decisionIcon: String? {
        switch decision {
        case .keep:     return "checkmark"
        case .delete:   return "trash"
        case .favorite: return "star.fill"
        case .none:     return nil
        }
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(height: 130)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
            if isBest {
                Image(systemName: "sparkles")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.accent, in: Circle())
                    .padding(5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let icon = decisionIcon {
                Image(systemName: icon)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(decisionColor, in: Circle())
                    .padding(5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(decisionColor, lineWidth: decision == nil ? 0 : 3)
        )
        .task(id: asset.localIdentifier) {
            image = await PhotoLibraryManager.shared.loadImage(
                for: asset, targetSize: CGSize(width: 320, height: 320))
        }
    }
}
