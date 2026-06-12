import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHuggingFace
import MLXLMTokenizers

/// Owns the mlx-swift-lm cleanup model (Qwen3 on the GPU; STT stays on the
/// ANE). Port of `cleanup.py`'s `CleanupEngine`, the same model-owner split as
/// `Transcriber`: `prepare()` loads + warms off the hot path (toggle-on),
/// `clean()` runs per utterance with a hard deadline. `nil` from `clean` means
/// deadline / model-not-ready — `runCleanup` turns every failure into the raw
/// transcript, so cleanup can only ever improve the text, never lose it.
actor CleanupEngine: CleanupCleaning {

    private var container: ModelContainer?
    private var preparing = false

    var isLoaded: Bool { container != nil }

    /// Download (first run, ~2.3 GB), load, and warm the model. Idempotent.
    /// Mirrors Python: a load failure leaves the engine unloaded (raw pastes,
    /// status timeout); a warmup failure still leaves it usable.
    func prepare(modelID: String) async {
        guard container == nil, !preparing else { return }
        preparing = true
        defer { preparing = false }

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: HubClient.default,
                using: TokenizersLoader(),
                configuration: ModelConfiguration(id: modelID))
            NSLog("cleanup: loaded %@ in %.1fs", modelID, CFAbsoluteTimeGetCurrent() - t0)
            container = loaded
        } catch {
            NSLog("cleanup: model load FAILED: %@", String(describing: error))
            return
        }

        // Warmup doubles as the Metal kernel compile; one tiny generation.
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await clean("um hello", style: "light", timeoutS: 120.0)
            NSLog("cleanup: warmup %.1fs", CFAbsoluteTimeGetCurrent() - t0)
        } catch {
            NSLog("cleanup: warmup failed: %@", String(describing: error))
        }
    }

    /// Generate cleaned text, or `nil` on deadline / model not ready.
    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
        guard let container else {
            NSLog("cleanup: model not loaded yet, skipping")
            return nil
        }
        // The STT pass that just ran leaves the MLX buffer pool full of
        // Parakeet-shaped buffers, which slowed the first generation by ~0.5s
        // in the Python engine (ARCHITECTURE.md). Dropping the pool is cheaper;
        // the next recording re-allocates off the stop-to-text critical path.
        Memory.clearCache()
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutS
        let chat = Self.toChat(CleanupLogic.buildMessages(text: text, style: style))

        return try await container.perform { context in
            // Qwen3 is a hybrid-thinking model: without enable_thinking=false
            // it emits <think> blocks and blows the latency budget.
            let lmInput = try await context.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
            let maxTokens = max(64, min(2 * context.tokenizer.encode(text: text).count, 1024))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)

            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: params, context: context)
            let tGen = CFAbsoluteTimeGetCurrent()
            var parts: [String] = []
            for await generation in stream {
                switch generation {
                case .chunk(let piece):
                    parts.append(piece)
                    if CFAbsoluteTimeGetCurrent() > deadline {
                        // Returning ends stream consumption; the generation
                        // task is cancelled via the stream's onTermination.
                        NSLog("cleanup: deadline %.1fs hit, falling back to raw", timeoutS)
                        return nil
                    }
                case .info(let info):
                    NSLog(
                        "cleanup: gen %.2fs prefill=%dtok@%.0ftps decode=%dtok@%.1ftps cached=%@",
                        CFAbsoluteTimeGetCurrent() - tGen,
                        info.promptTokenCount, info.promptTokensPerSecond,
                        info.generationTokenCount, info.tokensPerSecond,
                        "no")
                default:
                    break
                }
            }
            return parts.joined()
        }
    }

    private static func toChat(_ messages: [ChatMessage]) -> [Chat.Message] {
        messages.map { message in
            switch message.role {
            case "system": return .system(message.content)
            case "assistant": return .assistant(message.content)
            default: return .user(message.content)
            }
        }
    }
}
