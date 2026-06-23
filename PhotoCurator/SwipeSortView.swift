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

    // MARK: Card stack

    private var cardStack: some View {
        ZStack {
            // 背景カード（次の1枚）
            if index + 1 < deck.count {
                cardFace(deck[index + 1])
                    .scaleEffect(0.94)
                    .offset(y: 12)
            }
            // 手前のカード
            if let c = current {
                cardFace(c)
                    .offset(x: drag.width, y: drag.height)
                    .rotationEffect(.degrees(Double(drag.width / 18)))
                    .overlay(decisionLabels)
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { onDragEnded($0.translation) }
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func cardFace(_ card: SwipeCard) -> some View {
        SwipeCardImage(asset: card.asset)
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

    private var decisionLabels: some View {
        ZStack {
            badge(text: lm.s("残す", "KEEP"), color: Color.keepGreen, rotation: -12, alignment: .topLeading)
                .opacity(Double(max(0, drag.width) / hThreshold))
            badge(text: lm.s("削除", "DELETE"), color: Color.deleteRed, rotation: 12, alignment: .topTrailing)
                .opacity(Double(max(0, -drag.width) / hThreshold))
            badge(text: lm.s("お気に入り", "FAVORITE"), color: .orange, rotation: 0, alignment: .top)
                .opacity(Double(max(0, -drag.height) / vThreshold))
        }
        .padding(18)
    }

    private func badge(text: String, color: Color, rotation: Double, alignment: Alignment) -> some View {
        Text(text)
            .font(.title.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(rotation))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
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
        }
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
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task {
            image = await PhotoLibraryManager.shared.loadImage(
                for: asset, targetSize: CGSize(width: 1000, height: 1000))
        }
    }
}
