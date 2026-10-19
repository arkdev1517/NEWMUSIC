import Combine
import Foundation

struct DownloadedTrack: Codable, Identifiable, Sendable {
    var track: MusicTrack
    var fileName: String
    var byteCount: Int
    var downloadedAt: Date

    var id: String { track.id }
}

/// Offline downloads — the iOS counterpart of Android's `DownloadService` +
/// `DownloadStore`. A download resolves the same stream playback would (under
/// the download quality ceiling), writes it into app-private storage with
/// progress, and is preferred over the network on every later play.
///
/// Platform difference, stated plainly: Android downloads under a foreground
/// service and can write files into the shared Music folder with tags
/// embedded. iOS keeps downloads inside the app sandbox and a transfer only
/// runs while the app is active (plus the short system grace period); there
/// is no API to keep an arbitrary transfer alive indefinitely in the
/// background without a background URLSession handed over at launch, which
/// this app does not pretend to resume into.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloads: [DownloadedTrack] = []
    /// 0...1 progress for in-flight downloads, by track id.
    @Published private(set) var progress: [String: Double] = [:]
    /// Last failure per track id, shown where the download was started.
    @Published private(set) var failures: [String: String] = [:]

    private let service: any MusicService
    private let defaults: UserDefaults
    private let directory: URL
    private let manifestKey = "downloaded-tracks-manifest-v1"
    private let delegate = DownloadDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    private var tasks: [String: URLSessionDataTask] = [:]

    init(service: any MusicService, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.service = service
        self.defaults = defaults
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = support.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func isDownloaded(_ track: MusicTrack) -> Bool {
        downloads.contains { $0.track.id == track.id }
    }

    func isDownloading(_ track: MusicTrack) -> Bool {
        progress[track.id] != nil
    }

    func localURL(for track: MusicTrack) -> URL? {
        guard let entry = downloads.first(where: { $0.track.id == track.id }) else { return nil }
        let url = directory.appendingPathComponent(entry.fileName, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalBytes: Int { downloads.reduce(0) { $0 + $1.byteCount } }

    /// Downloads (or re-downloads) one track. Quality and network policy are
    /// the caller's call — this method only moves bytes.
    func download(_ track: MusicTrack, quality: AudioQuality) async {
        guard track.videoID != nil else {
            failures[track.id] = "Only YouTube Music tracks can be downloaded."
            return
        }
        guard progress[track.id] == nil else { return }
        failures[track.id] = nil
        progress[track.id] = 0
        do {
            let resolved = try await service.resolveStream(for: track, quality: quality)
            let fileName = "\(track.videoID ?? UUID().uuidString).m4a"
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            let temporary = directory.appendingPathComponent("\(fileName).part", isDirectory: false)
            try? FileManager.default.removeItem(at: temporary)

            var request = URLRequest(url: resolved.url)
            for (name, value) in resolved.headers { request.setValue(value, forHTTPHeaderField: name) }
            let trackID = track.id
            let byteCount = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let task = delegate.start(
                    session: session,
                    request: request,
                    destination: temporary,
                    onProgress: { value in
                        Task { @MainActor [weak self] in self?.progress[trackID] = value }
                    },
                    onComplete: { result in
                        Task { @MainActor [weak self] in self?.tasks[trackID] = nil }
                        continuation.resume(with: result)
                    }
                )
                tasks[trackID] = task
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            downloads.removeAll { $0.track.id == track.id }
            downloads.insert(
                DownloadedTrack(track: track, fileName: fileName, byteCount: byteCount, downloadedAt: Date()),
                at: 0
            )
            persist()
            progress[track.id] = nil
        } catch is CancellationError {
            progress[track.id] = nil
        } catch {
            progress[track.id] = nil
            failures[track.id] = error.localizedDescription
        }
    }

    func cancel(_ track: MusicTrack) {
        tasks[track.id]?.cancel()
        tasks[track.id] = nil
        progress[track.id] = nil
    }

    func delete(_ track: MusicTrack) {
        guard let entry = downloads.first(where: { $0.track.id == track.id }) else { return }
        let url = directory.appendingPathComponent(entry.fileName, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
        downloads.removeAll { $0.track.id == track.id }
        persist()
    }

    func deleteAll() {
        for entry in downloads {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
        }
        downloads = []
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: manifestKey),
              let decoded = try? JSONDecoder().decode([DownloadedTrack].self, from: data) else { return }
        // A manifest entry whose file vanished (system cleanup, restore) is
        // dropped rather than offered as a download that cannot play.
        downloads = decoded.filter { entry in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.fileName).path)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(downloads) else { return }
        defaults.set(data, forKey: manifestKey)
    }
}

/// Streams response bodies to disk with progress. One job per task, keyed by
/// the taskIdentifier URLSession assigns; all callbacks fire on the session's
/// delegate queue and the manager hops to the main actor itself.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    private struct Job {
        var handle: FileHandle
        var destination: URL
        var expectedBytes: Int64
        var receivedBytes: Int64 = 0
        var onProgress: (Double) -> Void
        var onComplete: (Result<Int, Error>) -> Void
    }

    private var jobs: [Int: Job] = [:]
    private let lock = NSLock()

    func start(
        session: URLSession,
        request: URLRequest,
        destination: URL,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<Int, Error>) -> Void
    ) -> URLSessionDataTask {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let task = session.dataTask(with: request)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            // Nowhere to put the bytes (disk full, permissions): fail the
            // download rather than streaming it into the void. The task is
            // never resumed; the manager clears it on completion.
            DispatchQueue.global().async {
                onComplete(.failure(MusicRequestError.service("Could not create the download file.")))
            }
            return task
        }
        lock.lock()
        jobs[task.taskIdentifier] = Job(
            handle: handle,
            destination: destination,
            expectedBytes: 0,
            onProgress: onProgress,
            onComplete: onComplete
        )
        lock.unlock()
        task.resume()
        return task
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(dataTask, with: .failure(MusicRequestError.httpStatus(http.statusCode)))
            return
        }
        lock.lock()
        jobs[dataTask.taskIdentifier]?.expectedBytes = response.expectedContentLength
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var job = jobs[dataTask.taskIdentifier] else { lock.unlock(); return }
        // The throwing write, not the legacy one: a full disk here is a
        // failed download, not an Objective-C exception through Swift.
        var writeError: Error?
        do { try job.handle.write(contentsOf: data) } catch { writeError = error }
        if writeError == nil {
            job.receivedBytes += Int64(data.count)
            jobs[dataTask.taskIdentifier] = job
        }
        let expected = job.expectedBytes
        let received = job.receivedBytes
        let onProgress = job.onProgress
        lock.unlock()
        if let writeError {
            dataTask.cancel()
            finish(dataTask, with: .failure(writeError))
            return
        }
        if expected > 0 {
            onProgress(min(1, Double(received) / Double(expected)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let isCancel = (error as? URLError)?.code == .cancelled
            finish(task, with: .failure(isCancel ? CancellationError() : error))
            return
        }
        lock.lock()
        let received = jobs[task.taskIdentifier]?.receivedBytes ?? 0
        lock.unlock()
        finish(task, with: .success(Int(received)))
    }

    private func finish(_ task: URLSessionTask, with result: Result<Int, Error>) {
        lock.lock()
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        lock.unlock()
        try? job.handle.close()
        if case .failure = result {
            try? FileManager.default.removeItem(at: job.destination)
        }
        job.onComplete(result)
    }
}
