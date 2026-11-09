# Tolk — DeepL-style translator for macOS (personal)

Double Cmd+C anywhere -> popup near the cursor with a streaming translation from Qwen
(`qwen-translate` on vkbox Ollama, http://192.168.1.13:11434, OpenAI-compatible /v1 with
`reasoning_effort: "none"`), with rules/glossary from `~/Translate/rules.md`; Google fallback
when vkbox is off or busy with a game.

## Ownership (parallel sessions edit only their own files, commit nothing)
| Area | Files | Owner |
|---|---|---|
| Contracts | `Sources/TolkCore/Contracts.swift` | coordinator (change only by agreement) |
| Engine | `Sources/TolkCore/Engine/**`, `Sources/tolk-cli/**` | engine session |
| Input + packaging | `Sources/Tolk/Input/**`, `scripts/**`, `Resources/**` | input session |
| UI | `Sources/Tolk/UI/**` | UI session |
| Wiring | `Sources/Tolk/AppDelegate.swift`, `main.swift`, `Package.swift` | coordinator |

Build: `swift build` (Swift 6.2 CLT, no Xcode). Language mode Swift 5.

## v0.3 — full app (parallel sessions, same rules: own files only, no commits)
| Area | Files | Owner |
|---|---|---|
| Main window, Dock, translate page, settings, app icon | `Sources/Tolk/MainWindow/**`, `Sources/Tolk/UI/InputWindowController.swift`, `Resources/**`, `scripts/**` | main-window session |
| Glossary editor | `Sources/Tolk/Glossary/**`, `Sources/TolkCore/Glossary/**` | glossary session |
| Image / screenshot translate (OCR) | `Sources/Tolk/ImageTranslate/**` | image session |
| Popup, engine, contracts, wiring | `UI/TranslationPopupController.swift`, `UI/UIShared.swift`, `TolkCore/Engine/**`, `Contracts.swift`, `AppDelegate.swift` | coordinator |

## Models (Ollama on vkbox) — known quirks
Both models are switched in Settings → «Модель» (`TolkConfig.model`); the engine treats them the same.
| | `qwen-translate` (qwen3.6:35b-a3b) | `gemma-translate` (gemma4:26b) |
|---|---|---|
| Thinking | ON by default (~1 min per answer). Off only via `reasoning_effort: "none"` on /v1; `think:false` and `/no_think` do NOT work | same: ON by default (~150 s with load); `reasoning_effort: "none"` turns it off |
| Params in model | num_ctx 32768, temp 0.3, top_p 0.95, top_k 20, presence_penalty 1.5 | num_ctx 32768, temp 0.3, top_p 0.95, top_k 64 (no presence penalty) |
| Architecture | MoE ~3B active, hybrid attention: KV 32k ≈ 64 MB/slot | MoE 128 experts / 8 active (~4B), sliding window 1024: KV also small |
| Speed (warm, 16 texts, 2026-11-09) | 2.96 s avg | 3.45 s avg |
| JSON (notes, alternatives) | works | works (fewer notes, more conservative) |
Display name in UI comes from the model id (`OllamaProvider.displayName`). Requests always send `temperature: 0.1`
(translation) / 0.2–0.3 (notes, alternatives) — overrides the model default.
Server: `OLLAMA_NUM_PARALLEL=2` (tested: 6 concurrent → median wait 5.5 s vs 8.6 s with 1; 4 slots was worse: 27 s total,
model is partly on CPU). Single request ~0.8 s slower than with 1 slot.
Only one big model fits the 6 GB GPU; switching models costs a reload (first request after switch: 30–150 s).

## Versioning
- `VERSION` (e.g. `0.3.1`) is the only place to change the version. `scripts/build-app.sh` writes it to
  `CFBundleShortVersionString`, sets `CFBundleVersion` = commit count and `TolkGitCommit` = short hash
  (`-dirty` if there were uncommitted changes). Settings → «О программе» and crash reports show all three.
- Each release: bump `VERSION`, commit, `git tag vX.Y.Z`, then build/install. Tags: v0.1 … v0.3.1.
