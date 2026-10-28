import SwiftUI
import UIKit
import VisionKit

struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner

        init(_ parent: DocumentScanner) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

struct AddLinkSheet: View {
    var onAdd: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $text)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(add)
                    PasteButton(payloadType: String.self) { strings in
                        DispatchQueue.main.async {
                            if let first = strings.first {
                                text = first.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                } footer: {
                    Text("Wolf Companion downloads the page once, keeps just the article text, and reads it offline. In Safari you can also tap Share → Wolf Companion.")
                }
            }
            .navigationTitle("Add web article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(normalizedURL == nil)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private var normalizedURL: URL? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(" ") else { return nil }
        if !candidate.lowercased().hasPrefix("http://") && !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private func add() {
        guard let url = normalizedURL else { return }
        onAdd(url)
        dismiss()
    }
}

struct PasteTextSheet: View {
    var onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $title)
                }
                Section {
                    TextEditor(text: $body_)
                        .frame(minHeight: 240)
                    PasteButton(payloadType: String.self) { strings in
                        DispatchQueue.main.async {
                            if let first = strings.first { body_ = first }
                        }
                    }
                } header: {
                    Text("Text")
                }
            }
            .navigationTitle("Paste text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(title, body_)
                        dismiss()
                    }
                    .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
