import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import StoreKit
import UIKit

class IapHelper: NSObject, SKProductsRequestDelegate {
    static let shared = IapHelper()
    
    private let productIdentifiers: [Constants.IapProducts] = [.monthly, .yearly]
    private var productsArray = [SKProduct]()
    private var requestedPurchase: String!
    private var productsRequest: SKProductsRequest?
    
    func requestProductInfo() {
        let request = SKProductsRequest(productIdentifiers: Set(productIdentifiers.map { $0.rawValue }))
        request.delegate = self
        request.start()
    }
    
    func getProductWithIdentifier(identifier: String) -> SKProduct! {
        guard productsArray.count > 0 else {
            requestProductInfo()
            return nil
        }
        
        for p in productsArray {
            if p.productIdentifier.caseInsensitiveCompare(identifier) == .orderedSame {
                return p
            }
        }
        return nil
    }
    
    public func getPriceForIdentifier(identifier: String) -> String {
        guard let product = getProductWithIdentifier(identifier: identifier) else { return "" }

        let numberFormatter = NumberFormatter()
        numberFormatter.formatterBehavior = .behavior10_4
        numberFormatter.numberStyle = .currency
        numberFormatter.locale = product.priceLocale
        let formattedPrice = numberFormatter.string(from: product.price)
        return formattedPrice ?? ""
    }
    
    public func buyProduct(identifier: String) -> Bool {
        guard let product = getProductWithIdentifier(identifier: identifier), let _ = ServerSettings.syncingEmail() else {
            FileLog.shared.addMessage("IAPHelper Failed to initiate purchase of \(identifier)")
            return false
        }
        
        FileLog.shared.addMessage("IAPHelper Buying \(product.productIdentifier)")
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
        
        return true
    }

    public func getPaymentFrequencyForIdentifier(identifier: String) -> String {
        if identifier == Constants.IapProducts.monthly.rawValue {
            return L10n.month
        }
        else if identifier == Constants.IapProducts.yearly.rawValue {
            return L10n.year
        }
        return ""
    }
    
    // MARK: SKProductReuqestDelelgate
    
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        if response.products.count > 0 {
            productsArray = response.products
            NotificationCenter.postOnMainThread(notification: ServerNotifications.iapProductsUpdated)
        }
        else {
            let invalid = response.invalidProductIdentifiers
            for i in invalid {
                FileLog.shared.addMessage("IAPHelper Invalid appstore identifier \(i)")
            }
            NotificationCenter.postOnMainThread(notification: ServerNotifications.iapProductsFailed)
        }
        clearRequestAndHandler()
    }
    
    public func request(_ request: SKRequest, didFailWithError error: Error) {
        FileLog.shared.addMessage("IAPHelper Failed to load list of products \(error.localizedDescription)")
        NotificationCenter.postOnMainThread(notification: ServerNotifications.iapProductsFailed)
        clearRequestAndHandler()
    }
    
    private func clearRequestAndHandler() {
        productsRequest = nil
    }
}

// MARK: - Pricing String Helpers

extension IapHelper {
    /// Generates a string for a subscription price in the format of PRICE / FREQUENCY
    /// - Parameter product: The product to get the pricing string for
    /// - Returns: The formatted string or nil if the product isn't available or hasn't loaded yet
    func pricingStringWithFrequency(for product: Constants.IapProducts) -> String? {
        let pricing = getPriceForIdentifier(identifier: product.rawValue)
        let frequency = getPaymentFrequencyForIdentifier(identifier: product.rawValue)

        guard !pricing.isEmpty, !frequency.isEmpty else {
            return nil
        }

        return "\(pricing) / \(frequency)"
    }
}

// MARK: - Intro Offers: Free Trials

extension IapHelper {
    /// Returns the localized trial duration if there is one
    /// - Parameter identifier: The product to check
    /// - Returns: A formatted string (1 week) or nil if there is no offer available
    func localizedFreeTrialDuration(_ identifier: Constants.IapProducts) -> String? {
        guard let offer = getFreeTrialOffer(identifier) else {
            return nil
        }

        return offer.subscriptionPeriod.localizedPeriodString()
    }

    /// Returns the first product with a free trial
    /// The priority order is set by the productIdentifiers array
    /// - Returns: The product enum with a free trial or nil if there is no free trial
    typealias FreeTrialDetails = (duration: String, pricing: String)
    func getFirstFreeTrialDetails() -> FreeTrialDetails? {
        guard
            let product = productIdentifiers.first(where: { getFreeTrialOffer($0) != nil }),
            let duration = localizedFreeTrialDuration(product),
            let pricing = pricingStringWithFrequency(for: product)
        else {
            return nil
        }

        return (duration, pricing)
    }

    func isEligibleForFreeTrial() -> Bool {
        #warning("TODO: Update isEligibleForIntroOffer with a check from the server")
        return FeatureFlag.freeTrialsEnabled
    }

    /// Checks if there is a free trial introductory offer for the given product
    /// - Parameter identifier: The product to check
    /// - Returns: The SKProductDiscount or nil if there is no offer or the user is not eligible for one
    private func getFreeTrialOffer(_ identifier: Constants.IapProducts) -> SKProductDiscount? {
        guard
            isEligibleForFreeTrial(),
            let offer = getProductWithIdentifier(identifier: identifier.rawValue)?.introductoryPrice,
            offer.paymentMode == .freeTrial
        else {
            return nil
        }

        return offer
    }
}

// MARK: - SKPaymentTransactionObserver

extension IapHelper: SKPaymentTransactionObserver {
    func purchaseWasSuccessful(_ productId: String) {
        let product = getProductWithIdentifier(identifier: productId)
        let isFreeTrial = product?.introductoryPrice?.paymentMode == .freeTrial
        
        Analytics.track(.purchaseSuccessful, properties: ["product": productId, "is_free_trial": isFreeTrial])
    }
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        FileLog.shared.addMessage("IAPHelper number of transactions in SKPayemntTransaction queue    \(transactions.count)")
        var hasNewPurchasedReceipt = false
        let lowercasedProductIdentifiers = productIdentifiers.map { $0.rawValue.lowercased() }
        
        for transaction in transactions {
            let product = transaction.payment.productIdentifier
            let transactionDate = DateFormatHelper.sharedHelper.jsonFormat(transaction.transactionDate)
            FileLog.shared.addMessage("IAPHelper Processing transaction with id \(String(describing: transaction.transactionIdentifier)) \(transactionDate))")
            
            if lowercasedProductIdentifiers.contains(product.lowercased()) {
                switch transaction.transactionState {
                case .purchasing:
                    FileLog.shared.addMessage("IAPHelper Purchasing \(product)")
                case .purchased:
                    hasNewPurchasedReceipt = true
                    queue.finishTransaction(transaction)
                    FileLog.shared.addMessage("IAPHelper Purchase successful for \(product) ")
                    AnalyticsHelper.plusPlanPurchased()
                    
                    purchaseWasSuccessful(product)
                case .failed:
                    let e = transaction.error! as NSError
                    FileLog.shared.addMessage("IAPHelper Purchase FAILED for \(product), code=\(e.code) msg= \(e.localizedDescription)/")
                    queue.finishTransaction(transaction)
                    
                    if e.code == 0 || e.code == 2 { // app store couldn't be connected or user cancelled
                        NotificationCenter.postOnMainThread(notification: ServerNotifications.iapPurchaseCancelled)
                    }
                    else { // report error to user
                        NotificationCenter.postOnMainThread(notification: ServerNotifications.iapPurchaseFailed)
                    }
                case .deferred:
                    FileLog.shared.addMessage("IAPHelper Purchase deferred for \(product)")
                    NotificationCenter.postOnMainThread(notification: ServerNotifications.iapPurchaseDeferred)
                case .restored:
                    queue.finishTransaction(transaction)
                default:
                    break
                }
            }
            else {
                FileLog.shared.addMessage("IAPHelper mark non-subscription transaction as finished")
                queue.finishTransaction(transaction)
            }
        }
        
        if hasNewPurchasedReceipt {
            if ServerSettings.iapUnverifiedPurchaseReceiptDate() == nil {
                ServerSettings.setIapUnverifiedPurchaseReceiptDate(Date())
            }
            ApiServerHandler.shared.sendPurchaseReceipt(completion: { success in
                if success {
                    FileLog.shared.addMessage("IAPHelper successfully validated receipt")
                }
                else {
                    FileLog.shared.addMessage("IAPHelper failed to validate receipt, but as the AppStore purchase was successful mark as Plus user on this device")
                }
            })
            NotificationCenter.postOnMainThread(notification: ServerNotifications.iapPurchaseCompleted)
        }
    }
}

// MARK: - SKProductSubscriptionPeriod Helper Extension

private extension SKProductSubscriptionPeriod {
    /// Converts the period into a localized readable format, ie: 3 days, 1 month, 1 year, etc.
    /// - Returns: Localized formatted version of the subscription period
    func localizedPeriodString() -> String? {
        let calendarUnit: NSCalendar.Unit
        switch unit {
        case .day:
            calendarUnit = .day
        case .week:
            calendarUnit = .weekOfMonth
        case .month:
            calendarUnit = .month
        case .year:
            calendarUnit = .year
        @unknown default:
            return nil
        }

        return TimePeriodFormatter.format(numberOfUnits: numberOfUnits, unit: calendarUnit)
    }
}
