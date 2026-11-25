// AppFeedback.swift — an in-app feedback form. What the person writes,
// plus up to four photos, goes to this application's independent platform environment.
//
// Copy this file and AirDeviceProof.swift into the app target, unchanged
// except for `FeedbackConfig.endpoint`, `FeedbackConfig.appKey` and
// `FeedbackConfig.teamID`. Requires no packages, no Info.plist entries, and
// no account: a public ingestion key authorizes submission only. iOS 17 or later.
//
// With the App Attest capability and `teamID` set, each entry carries the
// device's proof (AirDeviceProof.swift). Without them — and always on the
// Simulator — feedback is still sent and stored, marked unverified.
//
// Usage — present the form from anywhere:
//   .sheet(isPresented: $showFeedback) { FeedbackView() }
// or send without the form:
//   try await FeedbackClient.send(message: "…", images: [uiImage])
//
// The form's strings are plain English; localize them like the rest of the
// app if the app is localized.

import PhotosUI
import SwiftUI
import UIKit

enum FeedbackConfig {
    /// The `feedbackEndpoint` and public `key` returned by `workers app-key`.
    static let endpoint = URL(string: "https://apps.air.build/v1/ingest/feedback")!
    static let appKey = "ak_production_8erdKCm7pSAzegQtqByvPtYpjFV2EnZaGxPYva_L5Z0"
    /// The Apple team id (DEVELOPMENT_TEAM) for App Attest; nil sends no proof.
    static let teamID: String? = "AC2DHWGJ96"
    static let maximumImages = 4
}

enum FeedbackClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends one piece of feedback. Images are downscaled to 2048 px on the
    /// long side and sent as JPEG, so a report with four screenshots stays
    /// small enough for cellular. On the main actor only to read the device
    /// strings from `UIDevice`. The photos are encoded, the body is built and
    /// the request is sent in a detached task, so none of it holds up the
    /// main actor.
    @MainActor
    static func send(message: String, images: [UIImage]) async throws {
        let osVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        // Encoding four photos and the JSON body takes long enough to freeze the
        // form's spinner while it runs on the main actor, so it is done in the
        // detached task together with the network wait.
        try await Task.detached(priority: .userInitiated) {
            try await deliver(message: message, images: images, osVersion: osVersion)
        }.value
    }

    /// Everything after the device strings. `nonisolated`, so it runs where the
    /// detached task puts it rather than on the main actor.
    private nonisolated static func deliver(message: String, images: [UIImage], osVersion: String) async throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let body: [String: Any] = [
            "message": message,
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "appBuild": info["CFBundleVersion"] as? String ?? "",
            "deviceModel": deviceModel,
            "osVersion": osVersion,
            "locale": Locale.current.identifier,
            "images": images.prefix(FeedbackConfig.maximumImages).compactMap { image -> [String: String]? in
                guard let data = jpegData(image) else { return nil }
                return ["mediaType": "image/jpeg", "data": data.base64EncodedString()]
            },
        ]

        var request = URLRequest(url: FeedbackConfig.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(FeedbackConfig.appKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bytes = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bytes
        request.timeoutInterval = 60
        // The proof signs these exact bytes; none is fine (stored unverified).
        let proof = await AirDeviceProof.headers(
            for: bytes, endpoint: FeedbackConfig.endpoint, appKey: FeedbackConfig.appKey, teamID: FeedbackConfig.teamID
        )
        for (name, value) in proof {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            // Localized here, where the message is made: the form shows it as it is.
            throw Failure(message: String(localized: "Couldn't send feedback. Please try again.",
                                           comment: "Feedback form: the feedback could not be sent"))
        }
        if !proof.isEmpty {
            await AirDeviceProof.handle(status: http.value(forHTTPHeaderField: "X-Attest-Status"))
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            // Localized here, where the message is made; the form shows it as it is.
            let fallback = String(localized: "The server answered \(http.statusCode).",
                                             comment: "Feedback form: the feedback server refused the feedback")
            throw Failure(message: reason ?? fallback)
        }
    }

    private static func jpegData(_ image: UIImage) -> Data? {
        downscaled(image).jpegData(compressionQuality: 0.8)
    }

    /// The hardware identifier (`iPhone17,2`), which is what a bug report needs;
    /// `UIDevice.model` only says "iPhone".
    private static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// `image` redrawn with its longest side at most 2048 px. The form keeps this
/// copy in place of the picked photo (a large one is hundreds of MB once decoded)
/// and the client sends it as JPEG, so the rule is written once.
private func downscaled(_ image: UIImage) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    let scale = min(1, 2048 / max(longest, 1))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
}

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var canSend: Bool {
        !sending && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What happened, or what would you like to see?", text: $message, axis: .vertical)
                        .lineLimit(5 ... 12)
                } footer: {
                    // Watchpost's one addition to the template: what the app does not add by itself,
                    // and a reminder that what the person writes or picks goes as written.
                    Text("Your server address, password and recordings aren't added automatically. Check your text and screenshots for private information before sending.",
                         comment: "Feedback form: what the app does not add by itself, and to check before sending")
                }
                Section {
                    if !images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(images.indices, id: \.self) { index in
                                    Image(uiImage: images[index])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                images.remove(at: index)
                                                pickerItems = []
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.6))
                                            }
                                            .padding(4)
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: FeedbackConfig.maximumImages - images.count,
                        matching: .images
                    ) {
                        Label("Add screenshots", systemImage: "photo.on.rectangle")
                    }
                    .disabled(images.count >= FeedbackConfig.maximumImages)
                } footer: {
                    Text("Up to \(FeedbackConfig.maximumImages) images. Feedback also includes the app version, device model, system version, language and region.")
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }.disabled(!canSend)
                    }
                }
            }
            .onChange(of: pickerItems) { _, items in
                Task { await load(items) }
            }
            .alert("Thank you", isPresented: $sent) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your feedback was sent.")
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard images.count < FeedbackConfig.maximumImages,
                  let data = try? await item.loadTransferable(type: Data.self)
            else { continue }
            // Decoding and shrinking a photo is too slow for the main actor, so it
            // runs in a detached task and only the small copy reaches `images`.
            let small = await Task.detached(priority: .userInitiated) {
                UIImage(data: data).map(downscaled)
            }.value
            guard let image = small else { continue }
            images.append(image)
        }
        pickerItems = []
    }

    private func send() {
        sending = true
        failure = nil
        Task {
            do {
                try await FeedbackClient.send(message: message, images: images)
                sent = true
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
