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
/// Outcome of `CleanupEngine.prepare()`.
///
/// `.loaded` carries the cold-start split so the caller sees both the model
/// load and the warmup (which doubles as the Metal-kernel compile). `.skipped`
/// is a no-op — the model was already resident or a load was already in
/// flight — so it must not be reported as a fresh cold-start stage. `.failed`
/// means the model load threw: the engine is left unloaded (per-utterance
/// `clean()` returns nil, raw transcript pastes), and the caller MUST surface
/// it loudly rather than proceeding as if cleanup were ready.
enum CleanupPrepareOutcome: Sendable {
    case loaded(loadMs: Double, warmupMs: Double)
    case skipped
    case failed(String)

    /// Full preparation time (load + warmup) for the cold-start breakdown, or
    /// `nil` when nothing loaded this call (skipped or failed).
    var prepareMs: Double? {
        if case let .loaded(loadMs, warmupMs) = self { return loadMs + warmupMs }
        return nil
    }
}

actor CleanupEngine: CleanupCleaning {

    /// One style's static prompt prefix (system + few-shot examples, ~95% of
    /// the prompt's tokens) and its prefilled KV cache. `KVCache` isn't
    /// Sendable; safe here because the entry is built inside the model actor,
    /// only read afterwards, and per-request `copy()`s never escape `perform`.
    private final class PrefixEntry: @unchecked Sendable {
        let prefix: [Int]
        let cache: [KVCache]
        init(prefix: [Int], cache: [KVCache]) {
            self.prefix = prefix
            self.cache = cache
        }
    }

    private enum PrefixCacheError: Error {
        case unexpectedOffset(got: Int, want: Int)
        case notTrimmable
    }

    private var container: ModelContainer?
    private var preparing = false
    private var prefixCaches: [String: PrefixEntry] = [:]

    /// Whether a hint-triggered prefix-cache rebuild is in flight. Coalesces
    /// overlapping updateTermsHint calls the way `preparing` coalesces
    /// prepare(): later calls just set the hint; the in-flight loop notices
    /// and rebuilds again, so the latest hint always wins.
    private var rebuildingHint = false

    /// Bumped on every successful load. The idle-eviction watchdog snapshots it
    /// before deciding to evict and passes it to `unload(ifGeneration:)`, so a
    /// load that races in after the decision (but before the unload lands on
    /// this actor) is detected and the eviction is skipped — otherwise the
    /// watchdog could drop a model that was just reloaded.
    private var loadGeneration = 0

    /// The current load generation (see `loadGeneration`), read on the actor.
    var generation: Int { loadGeneration }

    /// Custom-dictionary spelling rule injected into the cleanup prompt. Set at
    /// arm before `prepare()` so it's baked into the cached prefix (changing it
    /// is re-arm-required — the prefix cache is built once). Default "" keeps
    /// the prompt byte-identical to the no-dictionary case.
    private var termsHint = ""

    var isLoaded: Bool { container != nil }

    /// Set the dictionary prompt hint. Must precede `prepare()`/`buildPrefixCaches`
    /// so the hint rides inside the prefilled prefix.
    func setTermsHint(_ hint: String) { termsHint = hint }

    /// Hot-apply a dictionary words edit: swap the hint and, if the model is
    /// resident, rebuild the per-style prefix caches so the change takes
    /// effect on the next utterance — seconds of background prefill instead
    /// of a full re-arm. When the model isn't loaded this just stores the
    /// hint; the next prepare() bakes it in.
    ///
    /// Reentrancy: the actor suspends inside buildPrefixCaches, so a second
    /// edit or the idle-eviction unload can interleave. The loop re-checks
    /// the hint after every rebuild (latest wins), and a load-generation or
    /// container change mid-rebuild discards the orphaned work — mirroring
    /// prepare()'s `preparing` + `loadGeneration` guards.
    func updateTermsHint(_ hint: String) async {
        guard hint != termsHint else { return }
        termsHint = hint
        guard container != nil, !rebuildingHint else { return }
        rebuildingHint = true
        defer { rebuildingHint = false }
        var builtFor: String? = nil
        while builtFor != termsHint {
            guard container != nil else { return }   // evicted mid-loop; prepare() rebakes
            let target = termsHint
            let generation = loadGeneration
            prefixCaches = [:]
            await buildPrefixCaches()
            if container == nil || loadGeneration != generation {
                // Unload or a fresh load interleaved: that path owns the
                // caches now (unload cleared them; prepare rebuilds with the
                // current hint). Drop our orphaned work.
                if container == nil { prefixCaches = [:] }
                return
            }
            builtFor = target
        }
        NSLog("cleanup: prefix caches rebuilt for new dictionary hint")
    }

    /// Download (first run, ~2.3 GB), load, and warm the model. Idempotent.
    /// Mirrors Python: a load failure leaves the engine unloaded (raw pastes,
    /// status timeout); a warmup failure still leaves it usable.
    /// `onProgress` reports the download fraction [0, 1] while the ~2.3 GB
    /// first-run fetch is in flight, so the background load can surface a note
    /// instead of the first few dictations silently pasting raw.
    /// Returns a `CleanupPrepareOutcome` describing the cold-start breakdown
    /// (item 3): `.loaded` with the load + warmup split when the model came up
    /// this call, `.skipped` when nothing loaded (already resident or a load in
    /// flight), or `.failed` when the load threw — the last leaves the engine
    /// unloaded so the caller can surface the failure loudly instead of
    /// silently pasting raw.
    @discardableResult
    func prepare(
        modelID: String, onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> CleanupPrepareOutcome {
        guard container == nil, !preparing else { return .skipped }
        preparing = true
        defer { preparing = false }

        let loadMs: Double
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: HubClient.default,
                using: TokenizersLoader(),
                configuration: ModelConfiguration(id: modelID),
                progressHandler: { progress in onProgress?(progress.fractionCompleted) })
            loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            NSLog("cleanup: loaded %@ in %.1fs", modelID, loadMs / 1000)
            container = loaded
            loadGeneration &+= 1
        } catch {
            NSLog("cleanup: model load FAILED: %@", String(describing: error))
            return .failed(String(describing: error))
        }

        // Warmup: prefill the static prompt prefix per style (doubles as the
        // Metal kernel compile) and run one tiny generation. A warmup failure
        // is non-fatal (the model is loaded and usable), but it's timed and
        // folded into the returned span so the cold-start breakdown reflects
        // the full preparation cost.
        let t0 = CFAbsoluteTimeGetCurrent()
        await buildPrefixCaches()
        do {
            _ = try await clean("um hello", style: "light", timeoutS: 120.0)
            NSLog("cleanup: warmup %.1fs", CFAbsoluteTimeGetCurrent() - t0)
        } catch {
            NSLog("cleanup: warmup failed: %@", String(describing: error))
        }
        let warmupMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return .loaded(loadMs: loadMs, warmupMs: warmupMs)
    }

    /// Drop the model and prefix caches (toggle-off); re-arm reloads.
    func unload() {
        guard container != nil else { return }
        container = nil
        prefixCaches = [:]
        Memory.clearCache()
        NSLog("cleanup: unloaded")
    }

    /// Idle-evict variant: unload only if no load has completed since the
    /// caller snapshotted `generation`. Runs on the actor, so a `prepare()` that
    /// won the race to load the model bumps `loadGeneration` first and this
    /// no-ops — closing the check-then-unload window the watchdog would
    /// otherwise have. Returns whether the model was actually dropped.
    @discardableResult
    func unload(ifGeneration expected: Int) -> Bool {
        guard container != nil, loadGeneration == expected else { return false }
        unload()
        return true
    }

    /// Prefill a reusable KV cache of each style's static prompt prefix.
    ///
    /// The prefix is found empirically — the longest common token prefix of
    /// two renders with different texts — because the chat template renders
    /// some messages position-dependently (e.g. Qwen3 injects an empty
    /// <think> block into the final assistant turn only). A failure here is
    /// non-fatal: the style just runs uncached (M0's sanctioned fallback).
    private func buildPrefixCaches() async {
        guard let container else { return }
        let hint = termsHint
        for style in CleanupLogic.styles {
            do {
                let entry: PrefixEntry = try await container.perform { context in
                    let a = try await Self.renderTokens(
                        context, text: "placeholder one", style: style, termsHint: hint)
                    let b = try await Self.renderTokens(
                        context, text: "a different text entirely", style: style, termsHint: hint)
                    let prefix = Array(a.prefix(CleanupLogic.commonPrefixLen(a, b)))
                    // TokenIterator prefills the prompt into the cache and
                    // samples ahead; generate one token like Python's
                    // stream_generate(max_tokens=1), then trim the overshoot
                    // back off so the cache holds exactly the prefix.
                    let cache = context.model.newCache(parameters: nil)
                    var iterator = try TokenIterator(
                        input: LMInput(tokens: MLXArray(prefix.map(Int32.init))),
                        model: context.model, cache: cache,
                        parameters: GenerateParameters(maxTokens: 1, temperature: 0.0))
                    _ = iterator.next()
                    let offset = cache.first?.offset ?? 0
                    let over = offset - prefix.count
                    guard over >= 0, over <= 2 else {
                        throw PrefixCacheError.unexpectedOffset(got: offset, want: prefix.count)
                    }
                    if over > 0 {
                        guard cache.allSatisfy({ $0.isTrimmable }) else {
                            throw PrefixCacheError.notTrimmable
                        }
                        for layer in cache { _ = layer.trim(over) }
                    }
                    // `perform` requires arrays evaluated before they leave.
                    eval(cache.flatMap { $0.innerState() })
                    return PrefixEntry(prefix: prefix, cache: cache)
                }
                prefixCaches[style] = entry
                NSLog("cleanup: cached %d-token prefix for style=%@", entry.prefix.count, style)
            } catch {
                NSLog(
                    "cleanup: prefix cache failed for style=%@ (%@) — running uncached",
                    style, String(describing: error))
            }
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
        let cached = prefixCaches[style]
        let hint = termsHint

        return try await container.perform { context in
            var tokens = try await Self.renderTokens(
                context, text: text, style: style, termsHint: hint)
            // Reuse the prefilled static prefix: feed only the suffix tokens
            // with a copy of its KV cache (the deepcopy-per-request from
            // cleanup.py — `copy()` re-materializes, later updates never touch
            // the original). Falls through to the full prompt when unavailable.
            var cache: [KVCache]? = nil
            if let cached, tokens.count > cached.prefix.count,
                Array(tokens.prefix(cached.prefix.count)) == cached.prefix
            {
                tokens = Array(tokens.dropFirst(cached.prefix.count))
                cache = cached.cache.map { $0.copy() }
            }
            let maxTokens = max(64, min(2 * context.tokenizer.encode(text: text).count, 1024))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)

            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(tokens.map(Int32.init))),
                cache: cache, parameters: params, context: context)
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
                        cache == nil ? "no" : "prefix")
                default:
                    break
                }
            }
            return parts.joined()
        }
    }

    /// Tokenize one cleanup request through the model's chat template.
    /// Qwen3 is a hybrid-thinking model: without enable_thinking=false it
    /// emits <think> blocks and blows the latency budget.
    private static func renderTokens(
        _ context: ModelContext, text: String, style: String, termsHint: String
    ) async throws -> [Int] {
        let chat = toChat(CleanupLogic.buildMessages(text: text, style: style, termsHint: termsHint))
        let lmInput = try await context.processor.prepare(
            input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
        return lmInput.text.tokens.asArray(Int.self)
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
