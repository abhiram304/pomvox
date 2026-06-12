// murmur-bench — M0 spike harness. Times FluidAudio Parakeet TDT (CoreML/ANE)
// over the fixture WAVs and probes SlidingWindowAsrManager's volatile/confirmed
// promotion (the two-tone draft contract). Emits JSON shaped to line up with
// scripts/native_baseline.py.
//
//   native/scripts/make-fixtures.sh
//   swift run -c release murmur-bench [fixtures-dir] [--out path.json]
//
// First run downloads the CoreML models from Hugging Face — the one permitted
// network operation. The streaming probe feeds audio at real-time pace so the
// volatile/confirmed timeline reflects what a live HUD would actually see.

import AVFoundation
import FluidAudio
import Foundation

let RUNS = 3

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("murmur-bench: " + msg + "\n").utf8))
    exit(1)
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }
func ms3(_ s: Double) -> Double { (s * 1000).rounded() / 1000 }

// Read a WAV into 0.5 s AVAudioPCMBuffers in the file's own format —
// FluidAudio's AudioConverter normalizes internally (its docs warn against
// hand-decoding samples).
func chunkedBuffers(_ url: URL) throws -> (chunks: [AVAudioPCMBuffer], audioSeconds: Double) {
    let file = try AVAudioFile(forReading: url)
    let sr = file.processingFormat.sampleRate
    let chunkFrames = AVAudioFrameCount(sr / 2)
    var chunks: [AVAudioPCMBuffer] = []
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)!
        try file.read(into: buf, frameCount: chunkFrames)
        if buf.frameLength == 0 { break }
        chunks.append(buf)
    }
    return (chunks, Double(file.length) / sr)
}

var fixturesDir = "native/fixtures"
var outPath = "/tmp/murmur-native-swift.json"
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    if arg == "--out" { outPath = args.removeFirst() } else { fixturesDir = arg }
}

let wavs = (try? FileManager.default.contentsOfDirectory(
    at: URL(fileURLWithPath: fixturesDir), includingPropertiesForKeys: nil
))?.filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path } ?? []
if wavs.isEmpty { fail("no WAVs in \(fixturesDir) — run native/scripts/make-fixtures.sh") }

var report: [String: Any] = [:]

// --- Batch: AsrManager (Parakeet TDT 0.6b v3 on ANE) ---
let tLoad = now()
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asr = AsrManager(config: .default)
try await asr.loadModels(models)
let loadS = now() - tLoad

let decoderLayers = await asr.decoderLayerCount
var batchFiles: [String: Any] = [:]
for wav in wavs {
    var runs: [Double] = []
    var transcript = ""
    var audioS = 0.0
    for _ in 0..<RUNS {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)  // fresh per run, like a new dictation
        let t0 = now()
        let result = try await asr.transcribe(wav, decoderState: &state)
        runs.append(ms3(now() - t0))
        transcript = result.text
        audioS = result.duration
    }
    let name = wav.deletingPathExtension().lastPathComponent
    batchFiles[name] = ["runs_s": runs, "audio_s": audioS, "transcript": transcript]
    print("stt  \(name): \(runs)")
}
report["batch"] = ["load_s": ms3(loadS), "files": batchFiles]

// --- Streaming probe: volatile/confirmed promotion at real-time pace ---
// Two configs: the stock `.streaming` preset (minContextForConfirmation 10 s —
// expected to confirm nothing on short dictations) and a short-form tuning to
// test whether the knobs rescue Murmur-length utterances.
let shortform = SlidingWindowAsrConfig(
    chunkSeconds: 3.0,
    hypothesisChunkSeconds: 0.5,
    leftContextSeconds: 2.0,
    rightContextSeconds: 1.0,
    minContextForConfirmation: 3.0,
    confirmationThreshold: 0.80
)
let streamConfigs: [(String, SlidingWindowAsrConfig)] = [("streaming", .streaming), ("shortform", shortform)]

var streamingReport: [String: Any] = [:]
for (cfgName, cfg) in streamConfigs {
    var perFile: [String: Any] = [:]
    for wav in wavs {
        let (chunks, audioSeconds) = try chunkedBuffers(wav)
        let manager = SlidingWindowAsrManager(config: cfg)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .system)
        var timeline: [[String: Any]] = []
        var fed = 0.0
        for chunk in chunks {
            await manager.streamAudio(chunk)
            try await Task.sleep(nanoseconds: 500_000_000)  // real-time pacing
            fed += Double(chunk.frameLength) / chunk.format.sampleRate
            timeline.append([
                "audio_s": (fed * 100).rounded() / 100,
                "confirmed_chars": await manager.confirmedTranscript.count,
                "volatile_chars": await manager.volatileTranscript.count,
            ])
        }
        let t0 = now()
        let final = try await manager.finish()
        let name = wav.deletingPathExtension().lastPathComponent
        let firstVolatile = timeline.first { ($0["volatile_chars"] as! Int) > 0 }?["audio_s"]
        let firstConfirmed = timeline.first { ($0["confirmed_chars"] as! Int) > 0 }?["audio_s"]
        perFile[name] = [
            "audio_s": (audioSeconds * 100).rounded() / 100,
            "first_volatile_at_s": firstVolatile ?? NSNull(),
            "first_confirmed_at_s": firstConfirmed ?? NSNull(),
            "finalize_s": ms3(now() - t0),
            "final_text": final,
            "timeline": timeline,
        ]
        print("stream[\(cfgName)] \(name): volatile@\(firstVolatile ?? "never") confirmed@\(firstConfirmed ?? "never") finalize=\(ms3(now() - t0))s")
        await manager.cleanup()
    }
    streamingReport[cfgName] = perFile
}
report["streaming"] = streamingReport

let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
