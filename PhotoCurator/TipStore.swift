import Foundation
import StoreKit
import Combine

// MARK: - Tip Product IDs
// App Store Connect で登録する消耗型IAP のProduct IDと一致させてください

enum TipProductID: String, CaseIterable {
    case small  = "jp.yazawa.snapsort.tip.small"   // ¥160
    case medium = "jp.yazawa.snapsort.tip.medium"  // ¥320
    case large  = "jp.yazawa.snapsort.tip.large"   // ¥810
}

// MARK: - TipStore

@MainActor
class TipStore: ObservableObject {
    static let shared = TipStore()

    @Published var products:      [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var isLoading:     Bool = false
    @Published var hasLoaded:     Bool = false

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case success
        case failed(String)
    }

    private var transactionListener: Task<Void, Never>?

    private init() {
        print("TipStore: init called")
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        let ids = TipProductID.allCases.map { $0.rawValue }
        do {
            let fetched = try await Product.products(for: ids)
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            print("TipStore: Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                purchaseState = .success
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)
                    await transaction.finish()
                } catch {
                    print("TipStore: Transaction verification failed: \(error)")
                }
            }
        }
    }

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

// MARK: - StoreError

enum StoreError: Error {
    case failedVerification
}
