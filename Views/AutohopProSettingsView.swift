import StoreKit
import SwiftUI

// AI CONTEXT — Views/AutohopProSettingsView.swift ("Autohop Pro" page). Reached
// from a new top section in SettingsView (matches the NotificationSettingsView /
// DiagnosticLogView sub-screen pattern — same Form/cardBackground/rowLabel
// recipe). This is the ONLY entry point that calls AutohopProStore.purchase() —
// before this file, the relay/StoreKit plumbing (Docs/RELAY_TIER1_IMPLEMENTATION.md
// §4) had no caller. Status section shows Active/trial/not-subscribed derived
// from AutohopProStore.isPro/expirationDate; the purchase/restore buttons and
// "Manage Subscription" (StoreKit's own sheet, AppStore.showManageSubscriptions)
// are the only three user actions here. AppState observes isPro itself and
// drives relay register/unregister — this view does not talk to RelayClient.
struct AutohopProSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var store: AutohopProStore { appState.autohopProStore }

    private var cardBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return Color.white.opacity(0.08)
    }
    private var formScrollBackground: Visibility {
        if #available(iOS 26, *) { return .visible }
        return .hidden
    }
    private var formPageBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return .black
    }

    var body: some View {
        Form {
            statusSection
            if !store.isPro {
                benefitsSection
            }
            actionsSection
            if let error = store.lastError {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                .listRowBackground(cardBackground)
            }
        }
        .listSectionSpacing(28)
        .scrollContentBackground(formScrollBackground)
        .background(formPageBackground.ignoresSafeArea())
        .tint(.purple)
        .preferredColorScheme(.dark)
        .navigationTitle("Autohop Pro")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerBar()
        .task { await store.loadProduct() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                SettingsRowLabel(title: "Status", systemImage: "bolt.badge.clock")
                Spacer()
                Text(statusText)
                    .foregroundStyle(store.isPro ? .green : .secondary)
                    .font(.subheadline.weight(.semibold))
            }
        } footer: {
            if store.isPro, let expirationDate = store.expirationDate {
                Text("Renews \(expirationDate.formatted(date: .abbreviated, time: .omitted)).")
            }
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var benefitsSection: some View {
        Section {
            Label("Reliable background downloads, even overnight while the app is closed", systemImage: "arrow.down.circle")
            Label("Faster cross-device sync between iPhone and Apple TV", systemImage: "arrow.triangle.2.circlepath")
        } header: {
            Text("What you get")
        } footer: {
            if let product = store.product {
                Text(trialFooter(for: product))
            }
        }
        .listRowBackground(cardBackground)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if store.isPro {
                Button {
                    Task { await showManageSubscriptions() }
                } label: {
                    rowLabel("Manage Subscription", systemImage: "gearshape")
                }
            } else {
                Button {
                    Task { await store.purchase() }
                } label: {
                    HStack {
                        rowLabel(purchaseTitle, systemImage: "bolt.badge.clock")
                        Spacer()
                        if store.purchaseInFlight {
                            ProgressView()
                        }
                    }
                }
                .disabled(store.product == nil || store.purchaseInFlight)
            }

            Button {
                Task { await store.restorePurchases() }
            } label: {
                rowLabel("Restore Purchases", systemImage: "arrow.clockwise")
            }
            .disabled(store.purchaseInFlight)
        }
        .listRowBackground(cardBackground)
    }

    // MARK: - Helpers

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        SettingsRowLabel(title: title, systemImage: systemImage)
    }

    private var statusText: String {
        store.isPro ? "Active" : "Not Subscribed"
    }

    private var purchaseTitle: String {
        guard let product = store.product else { return "Loading…" }
        return "Subscribe — \(product.displayPrice)/month"
    }

    private func trialFooter(for product: Product) -> String {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else {
            return "\(product.displayPrice)/month, cancel anytime."
        }
        return "Starts with a free trial, then \(product.displayPrice)/month. Cancel anytime."
    }

    private func showManageSubscriptions() async {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        try? await AppStore.showManageSubscriptions(in: windowScene)
    }
}
