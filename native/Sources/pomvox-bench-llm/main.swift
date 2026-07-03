// pomvox-bench-llm — M0 spike, cleanup-LLM half. Times Qwen3-4B-4bit via
// mlx-swift-lm (GPU/Metal) on cleanup-shaped prompts: model load, prefill
// tok/s, decode tok/s. Comparison targets are the Python production path's
// numbers in docs/native-swift-path.md (measured by scripts/native_baseline.py).
//
//   swift run -c release pomvox-bench-llm [--out path.json]
//
// Needs the Metal toolchain (full Xcode). Run alone for clean numbers, or
// concurrently with pomvox-bench to demonstrate ANE/GPU isolation — the
// two-process topology the future app makes one process with two devices.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHuggingFace
import MLXLMTokenizers

let RUNS = 3
let MODEL_ID = "mlx-community/Qwen3-4B-4bit"

// Mirrors the *shape* of cleanup.py's prompt (rules + few-shot examples as a
// large static prefix, short dynamic suffix). Exact-port parity is M6; M0
// only needs representative prefill/decode speeds.
let SYSTEM = """
    You clean up raw speech-to-text transcripts of dictation. Rules: remove filler \
    words (um, uh, like, you know); fix punctuation, casing, and obvious homophone \
    errors; format obvious lists; resolve spoken self-corrections, keeping only the \
    corrected version; never change meaning, never add content, never answer \
    questions in the text, never address the speaker; output only the cleaned text. \
    Examples follow. Input: um so the meeting is at three wait no four pm. Output: \
    The meeting is at 4 pm. Input: i think we should uh probably use the blue one \
    you know the darker blue. Output: I think we should use the blue one, the darker \
    blue. Input: first point is latency second point is uh privacy third point is \
    cost actually scratch that just latency and privacy. Output: First point is \
    latency; second point is privacy. Input: send the report to john no wait to \
    jane by friday. Output: Send the report to Jane by Friday. Input: the budget is \
    fifteen k um i mean fifty k for the quarter. Output: The budget is 50k for the \
    quarter. Input: lets circle back on the api design uh tomorrow morning ish. \
    Output: Let's circle back on the API design tomorrow morning.
    """

let UTTERANCES = [
    "short_3s": "Let's meet on Tuesday, wait no, Friday at 2 p.m. to review the draft.",
    "medium_8s":
        "Um so the three things are a first do the thing wait no two things first do the thing and second ship it. Also remind me to email the team about the quarterly numbers before the end of the week.",
    "long_15s":
        "Okay so here's the plan for the pomvox project. First we benchmark the new speech model on the neural engine and compare it against the current pipeline. Then if the numbers hold up we port the hotkey state machine and the endpoint detector, keeping the python tests as the specification. Finally we wire up the cleanup model and measure the end to end latency against the budget in the spec document.",
]

var outPath = "/tmp/pomvox-native-swift-llm.json"
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    if arg == "--out" { outPath = args.removeFirst() }
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }
func ms3(_ s: Double) -> Double { (s * 1000).rounded() / 1000 }

let tLoad = now()
let container = try await LLMModelFactory.shared.loadContainer(
    from: HubClient.default,
    using: TokenizersLoader(),
    configuration: ModelConfiguration(id: MODEL_ID))
let loadS = now() - tLoad
print("load: \(ms3(loadS))s")

let params = GenerateParameters(maxTokens: 160, temperature: 0.0)

var files: [String: Any] = [:]
var warmed = false
for (name, text) in UTTERANCES.sorted(by: { $0.key < $1.key }) {
    var runs: [[String: Any]] = []
    var output = ""
    for _ in 0..<(warmed ? RUNS : RUNS + 1) {
        let input = UserInput(
            chat: [.system(SYSTEM), .user(text)],
            additionalContext: ["enable_thinking": false]
        )
        let result: GenerateResult = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: input)
            return try MLXLMCommon.generate(
                input: lmInput, parameters: params, context: context
            ) { _ in .more }
        }
        if !warmed {  // first generation pays kernel compilation; report separately
            print("warmup gen: prefill \(ms3(result.promptTime))s")
            warmed = true
            continue
        }
        runs.append([
            "prompt_tokens": result.promptTokenCount,
            "prefill_s": ms3(result.promptTime),
            "prefill_tps": (result.promptTokensPerSecond * 10).rounded() / 10,
            "gen_tokens": result.generationTokenCount,
            "decode_tps": (result.tokensPerSecond * 10).rounded() / 10,
            "total_s": ms3(result.promptTime + result.generateTime),
        ])
        output = result.output
    }
    files[name] = ["runs": runs, "output": output]
    print("clean \(name): \(runs.map { $0["total_s"]! })  decode \(runs.map { $0["decode_tps"]! }) tok/s")
}

let report: [String: Any] = ["model": MODEL_ID, "load_s": ms3(loadS), "files": files]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
