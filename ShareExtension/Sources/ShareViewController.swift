import UIKit
import UniformTypeIdentifiers

/// "Share → Wolf Companion" from Safari or any app. Saves the link (or selected text) for the
/// main app to import the next time it opens.
final class ShareViewController: UIViewController {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCard()
        Task { await handleShare() }
    }

    private func buildCard() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        iconView.image = UIImage(systemName: "waveform")
        iconView.tintColor = .systemPurple
        iconView.contentMode = .scaleAspectFit
        iconView.isHidden = true

        titleLabel.text = "Saving to Wolf Companion…"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, iconView, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            iconView.heightAnchor.constraint(equalToConstant: 34),
            iconView.widthAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func handleShare() async {
        guard let item = await sharedItem() else {
            show(title: "Nothing to save", detail: "Share a web page or some text.")
            await close(after: 1.5)
            return
        }

        if SharedInbox.add(item) {
            show(title: "Saved to Wolf Companion", detail: "Open Wolf Companion to start listening.")
        } else {
            // No shared container in this install: put it on the clipboard instead.
            switch item.kind {
            case .url: UIPasteboard.general.url = URL(string: item.value)
            case .text: UIPasteboard.general.string = item.value
            }
            show(title: "Copied for Wolf Companion",
                 detail: item.kind == .url
                    ? "Open Wolf Companion and tap Paste on the Home screen."
                    : "Open Wolf Companion, then tap Paste text.")
        }
        await close(after: 1.2)
    }

    private func sharedItem() async -> SharedInbox.Item? {
        let extensionItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        let pageTitle = extensionItems.first?.attributedContentText?.string

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return SharedInbox.Item(kind: .url, value: url.absoluteString, title: pageTitle, date: Date())
            }
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https"), !trimmed.contains(" ") {
                    return SharedInbox.Item(kind: .url, value: trimmed, title: nil, date: Date())
                }
                if !trimmed.isEmpty {
                    return SharedInbox.Item(kind: .text, value: trimmed, title: nil, date: Date())
                }
            }
        }
        return nil
    }

    private func show(title: String, detail: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        iconView.isHidden = false
        titleLabel.text = title
        detailLabel.text = detail
    }

    private func close(after seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        extensionContext?.completeRequest(returningItems: nil)
    }
}
