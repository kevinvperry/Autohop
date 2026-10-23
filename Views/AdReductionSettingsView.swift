import SwiftUI

struct AdReductionSettingsView: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Toggle("Reduce inserted ads", isOn: $settings.appSettings.adReduction.enabled)
                    .disabled(settings.appSettings.adReduction.endpoint.isEmpty || RelayCredentialStore.read() == nil)
            } footer: {
                Text("Download selected public podcasts through Luxembourg to reduce some geographically targeted ads. Some ads will remain. Existing downloads are unchanged. This is an experimental feature.")
            }
            Section("Relay setup") {
                TextField("HTTPS relay address", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Access token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(checking ? "Checking…" : "Check and save relay") {
                    Task { await checkAndSave() }
                }.disabled(checking)
                if let message { Text(message).font(.footnote).accessibilityLabel(message) }
            }
            Section {
                ForEach(subscriptions.subscriptions.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { show in
                    Toggle(show.title, isOn: Binding(
                        get: { settings.appSettings.adReduction.publicSubscriptionIDs.contains(show.id) },
                        set: { enabled in
                            if enabled { settings.appSettings.adReduction.publicSubscriptionIDs.insert(show.id) }
                            else { settings.appSettings.adReduction.publicSubscriptionIDs.remove(show.id) }
                        }
                    ))
                }
            } header: { Text("Public podcasts") }
            footer: {
                Text("Select only feeds you know are public. Leave private, paid and authenticated feeds off. The relay receives episode URLs and your connection IP. Access tokens stay in this device’s Keychain. Unselected shows download normally. Relay failures never silently fall back to normal downloads.")
            }
            Section {
                Text("A Luxembourg server must be provisioned and its outbound IP verified before use. A successful connection check confirms the relay configuration, not its physical location or that ads will be removed.")
                Text("To replace an existing download, remove its local file first, then download again. Different ad lengths can change chapters and playback positions.")
            }.font(.footnote)
        }
        .navigationTitle("Reduce inserted ads")
        .onAppear { endpoint = settings.appSettings.adReduction.endpoint }
    }

    @MainActor private func checkAndSave() async {
        checking = true
        defer { checking = false }
        do {
            guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RelayDownloadError.notConfigured
            }
            let credential = token.isEmpty ? RelayCredentialStore.read() ?? "" : token
            _ = try DownloadDelivery.luxembourg(endpoint: base, token: credential)
                .request(for: URL(string: "https://example.com/episode.mp3")!)
            var request = URLRequest(url: base.appendingPathComponent("v1/status"))
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let session = URLSession(configuration: .ephemeral, delegate: StatusRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            struct Status: Decodable { let enabled: Bool; let region: String; let version: Int }
            let status = try JSONDecoder().decode(Status.self, from: data)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  status.enabled, status.region == "LU", status.version == 1 else {
                throw RelayDownloadError.unavailable
            }
            try RelayCredentialStore.save(credential)
            settings.appSettings.adReduction.endpoint = base.absoluteString
            token = ""
            message = "Relay connected. Select public podcasts, then turn on ad reduction."
        } catch { message = error.localizedDescription }
    }
}

private final class StatusRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
