import UIKit
import UniformTypeIdentifiers

/// Share Extension that receives files from the share sheet and passes them
/// to the main Manicule app for opening.
class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        handleSharedFile()
    }

    private func handleSharedFile() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {
            close()
            return
        }

        // Load as file representation — this gives us a temporary copy we can work with
        provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { [weak self] url, error in
            guard let self, let url else {
                DispatchQueue.main.async { self?.close() }
                return
            }

            // Copy to the shared App Group container so the main app can access it
            let sharedContainer = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.palefire.manicule"
            )
            guard let inbox = sharedContainer?.appendingPathComponent("Inbox", isDirectory: true) else {
                DispatchQueue.main.async { self.close() }
                return
            }

            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let dest = inbox.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)

            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                DispatchQueue.main.async { self.close() }
                return
            }

            // Store the pending file path in shared UserDefaults so the main app
            // can pick it up when it becomes active (fallback mechanism)
            let sharedDefaults = UserDefaults(suiteName: "group.com.palefire.manicule")
            sharedDefaults?.set(dest.path, forKey: "pendingSharedFile")
            sharedDefaults?.synchronize()

            // Try to open the main app via custom URL scheme
            let encoded = dest.absoluteString.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? ""
            let openURL = URL(string: "manicule://shared?url=\(encoded)")

            DispatchQueue.main.async {
                if let openURL {
                    self.extensionContext?.open(openURL) { success in
                        if !success {
                            // URL open not supported by host — the file is still in
                            // the shared container and will be picked up when the user
                            // opens Manicule manually.
                        }
                        self.close()
                    }
                } else {
                    self.close()
                }
            }
        }
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
