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
