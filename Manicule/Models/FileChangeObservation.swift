import Foundation

/// Own in a window task and call stop() in its defer. The explicit lifetime is
/// necessary because NSFileCoordinator retains registered presenters.
@MainActor
final class FileChangeObservation: NSObject, NSFilePresenter {
    nonisolated let presentedItemURL: URL?
    nonisolated let presentedItemOperationQueue = OperationQueue.main
    let changes: AsyncStream<URL>
    nonisolated private let continuation: AsyncStream<URL>.Continuation

    init(url: URL) {
        presentedItemURL = url
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        continuation.finish()
    }

    nonisolated func presentedItemDidChange() {
        if let url = presentedItemURL { continuation.yield(url) }
    }

    nonisolated func presentedItemDidMove(to newURL: URL) {
        continuation.yield(newURL)
    }

    nonisolated func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        presentedItemDidChange()
        completionHandler(nil)
    }
}
