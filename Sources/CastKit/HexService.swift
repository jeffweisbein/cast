#if os(macOS)
import Foundation
import Security

struct HexModel: Decodable {
    let id: String
    let name: String
    let installed: Bool
    let verified: Bool
    let downloadBytes: Int?
}

/// A direct child with an stdin lifetime lease. No Node runtime, cloud API or clipboard.
@MainActor
final class HexService {
    static let model = "parakeet_unified_en"
    private let executableOverride: URL?
    init(executable: URL? = nil) { self.executableOverride = executable }
    private var process: Process?
    private var lease: Pipe?
    private var endpoint: URL?
    private var token = ""
    private var startupTask: Task<Void, Never>?
    private var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config, delegate: LoopbackOnlyRedirects(), delegateQueue: nil)
    }()

    static var executable: URL? {
        let candidates = [Bundle.main.url(forResource: "Hex", withExtension: "app", subdirectory: "Helpers")?.appendingPathComponent("Contents/MacOS/hex"),
                          URL(fileURLWithPath: "/Applications/Hex.app/Contents/MacOS/hex"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Hex.app/Contents/MacOS/hex")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func validateHandshake(_ data: Data, pid: Int32) throws -> (URL, String) {
        struct Ready: Decodable { let type: String; let url: String; let token: String; let apiVersion: String; let pid: Int32 }
        let ready = try JSONDecoder().decode(Ready.self, from: data)
        guard ready.type == "ready", ready.apiVersion == "2", ready.pid == pid,
              let url = URL(string: ready.url), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, port > 0, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              !ready.token.isEmpty, !ready.token.contains(where: { $0.isWhitespace }) else {
            throw DictationFailure(message: "The Hex helper returned an incompatible local endpoint.")
        }
        return (url, ready.token)
    }

    func start() async throws {
        if process?.isRunning == true, endpoint != nil { return }
        close()
        guard let executable = executableOverride ?? Self.executable else {
            throw DictationFailure(message: "Install Hex in Applications, then return to Dictation Setup. Cast uses its local engine without opening Hex.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let requirementText = "anchor apple generic and identifier \"anomaly.hex\" and certificate leaf[subject.OU] = \"5NZ4Q7NXJ4\""
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw DictationFailure(message: "The Hex helper signature is invalid. Reinstall the signed Hex release.")
        }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = executable
        child.arguments = ["service", "--embedded"]
        // Do not inherit diagnostic flags that can retain audio/transcripts.
        child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        process = child; lease = input
        try child.run()
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                var buffer = Data()
                var completed = false
                @MainActor func finish(_ result: Result<Data, Error>) {
                    guard !completed else { return }
                    completed = true
                    output.fileHandleForReading.readabilityHandler = nil
                    startupTask?.cancel(); startupTask = nil
                    continuation.resume(with: result)
                }
                output.fileHandleForReading.readabilityHandler = { handle in
                    let part = handle.availableData
                    Task { @MainActor in
                        guard !completed else { return }
                        buffer.append(part)
                        if let end = buffer.firstIndex(of: 10) { finish(.success(buffer.prefix(upTo: end))) }
                        else if part.isEmpty || buffer.count > 16_384 { finish(.failure(DictationFailure(message: "Hex did not return a valid startup response."))) }
                    }
                }
                startupTask = Task {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    finish(.failure(DictationFailure(message: "Hex startup timed out.")))
                }
            }
            try Task.checkCancellation()
            let ready = try Self.validateHandshake(data, pid: child.processIdentifier)
            endpoint = ready.0; token = ready.1
        } catch { close(); throw error }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let endpoint, let url = URL(string: path, relativeTo: endpoint) else { throw DictationFailure(message: "Hex is not running.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DictationFailure(message: "Hex rejected the request. Check the installed model and retry.")
        }
    }

    func models() async throws -> [HexModel] {
        let (data, response) = try await session.data(for: request("/models?language=en"))
        try check(response)
        return try JSONDecoder().decode([HexModel].self, from: data)
    }

    func prepare(progress: @escaping (String) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request("/models/\(Self.model)/prepare?language=en", method: "POST"))
        try check(response)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            guard let data = line.dropFirst(5).data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else {
                throw DictationFailure(message: "Invalid Hex model progress.")
            }
            switch type {
            case "ok": progress("Model ready"); return
            case "downloading":
                let downloaded = (event["downloadedBytes"] as? NSNumber)?.int64Value ?? 0
                let total = (event["totalBytes"] as? NSNumber)?.int64Value ?? 0
                progress("Downloading \(ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
            case "loading": progress("Loading local speech model…")
            case "verifying": progress("Verifying model download…")
            default: throw DictationFailure(message: "Hex could not prepare the model.")
            }
        }
        throw DictationFailure(message: "Hex model setup ended before it was ready.")
    }

    func transcribe(_ wav: Data) async throws -> String {
        guard wav.count <= 64 * 1024 * 1024 else { throw DictationFailure(message: "This recording is too large to transcribe locally.") }
        let (data, response) = try await session.data(for: request("/transcriptions?model=\(Self.model)&language=en", method: "POST", body: wav))
        try check(response)
        struct Transcript: Decodable { let transcript: String }
        return try JSONDecoder().decode(Transcript.self, from: data).transcript
    }

    func close() {
        try? lease?.fileHandleForWriting.close()
        lease = nil
        if let child = process, child.isRunning {
            child.terminate()
            // Exact owned child only; never signal by process name or a recycled PID.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        process = nil; endpoint = nil; token = ""
    }
}

private final class LoopbackOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
