import AVFoundation
import CParakeet
import Foundation

/// Homebrew's ggml ships Metal/CPU as dynamically loaded backends. Every model init must touch this first
/// (Swift runs global initializers exactly once, thread-safely).
let ggmlBackends: Void = ggml_backend_load_all()

/// On-device speech-to-text: Parakeet TDT via whisper.cpp's libparakeet (Metal). The model stays loaded.
final class Parakeet {
    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "murmur.parakeet", qos: .userInitiated)

    init(modelPath: String) throws {
        ggmlBackends
        var params = parakeet_context_default_params()
        params.use_gpu = true
        guard let ctx = parakeet_init_from_file_with_params(modelPath, params) else {
            throw MurmurError.message("Could not load speech model at \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit { parakeet_free(ctx) }



    /// Transcribes 16 kHz mono float samples.
    func transcribe(_ samples: [Float]) async -> String {
        await withCheckedContinuation { cont in
            queue.async { [ctx] in
                // A short tail of silence keeps the last word from being clipped.
                let padded = samples + [Float](repeating: 0, count: 4800)
                var p = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
                p.n_threads = 4
                p.no_context = true
                let rc = padded.withUnsafeBufferPointer { buf in
                    parakeet_full(ctx, p, buf.baseAddress, Int32(buf.count))
                }
                guard rc == 0 else { return cont.resume(returning: "") }
                var parts: [String] = []
                for i in 0..<parakeet_full_n_segments(ctx) {
                    if let c = parakeet_full_get_segment_text(ctx, i) { parts.append(String(cString: c)) }
                }
                let text = parts.joined(separator: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text)
            }
        }
    }

    /// Runs one tiny inference so the first real dictation doesn't pay Metal warm-up cost.
    func warmUp() async { _ = await transcribe([Float](repeating: 0, count: 8000)) }
}

/// Captures the default input device and resamples to 16 kHz mono.
final class Recorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Called on the audio thread with a 0...1 loudness value.
    var onLevel: ((Float) -> Void)?
    /// Called on the audio thread with each new block of 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    /// Called when the audio route changes mid-recording and the engine stops.
    var onInterrupted: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MurmurError.message("No microphone available")
        }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            throw error
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onInterrupted?() }
    }

    func stop() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        return lock.withLock { samples }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        if n > 0 {
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
            onLevel?(min(max((db + 55) / 45, 0), 1))
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        onSamples?(Array(chunk))
    }
}

/// Streaming voice-activity detection with Silero (whisper.cpp). Reports one speech probability per 32 ms frame.
final class VoiceDetector {
    static let frame = 512 // samples per probability at 16 kHz
    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "murmur.vad", qos: .userInitiated)
    private var pending: [Float] = []

    init(modelPath: String) throws {
        ggmlBackends
        var params = whisper_vad_default_context_params()
        params.n_threads = 1
        params.use_gpu = false // tiny model; CPU avoids contending with Parakeet on the GPU
        guard let ctx = whisper_vad_init_from_file_with_params(modelPath, params) else {
            throw MurmurError.message("Could not load voice detector at \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit { whisper_vad_free(ctx) }

    /// Clears the LSTM state between recordings.
    private var generation = 0

    func reset() {
        queue.async { [self] in
            generation += 1
            pending.removeAll()
            whisper_vad_reset_state(ctx)
        }
    }

    /// Buffers samples and calls `onProbs` (off the main thread) with probabilities for each complete frame.
    func feed(_ samples: [Float], onProbs: @escaping (_ probs: [Float], _ generation: Int) -> Void) {
        queue.async { [self] in
            pending.append(contentsOf: samples)
            let usable = pending.count / Self.frame * Self.frame
            guard usable > 0 else { return }
            let ok = pending.withUnsafeBufferPointer { whisper_vad_detect_speech_no_reset(ctx, $0.baseAddress, Int32(usable)) }
            pending.removeFirst(usable)
            guard ok, let probs = whisper_vad_probs(ctx) else { return }
            onProbs(Array(UnsafeBufferPointer(start: probs, count: Int(whisper_vad_n_probs(ctx)))), generation)
        }
    }
}

/// Minimal client for the local Ollama server.
struct Ollama {
    var base = URL(string: "http://127.0.0.1:11434")!

    struct Message: Codable { var role: String; var content: String }

    func isUp() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    func chat(model: String, messages: [Message], temperature: Double = 0.2) async throws -> String {
        var text = ""
        for try await piece in stream(model: model, messages: messages, temperature: temperature) { text += piece }
        return text
    }

    func stream(model: String, messages: [Message], temperature: Double = 0.5, contextTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "keep_alive": "30m",
                        // One fixed window for every call, so Ollama never reloads the model between cleanup and Ask.
                        "options": ["temperature": temperature, "num_ctx": contextTokens ?? 16_384],
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw MurmurError.message("Ollama returned an error. Is \(model) pulled?")
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let err = obj["error"] as? String { throw MurmurError.message(err) }
                        if let msg = obj["message"] as? [String: Any], let c = msg["content"] as? String, !c.isEmpty {
                            continuation.yield(c)
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Loads the model into memory so the first request is fast.
    func warm(model: String) async {
        _ = try? await chat(model: model, messages: [.init(role: "user", content: "hi")])
    }
}

enum MurmurError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
