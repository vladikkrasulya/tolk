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

## v0.4.0 — reply mode and in-app help
- `UI/ReplyPanelController.swift`: «Ответ» window from the popup («Ответить» / R). Partner's message (full, scrolls
  when long) + reply input + live translation into the partner's language with `TranslationRequest.replyTo`
  (prompt «Conversation context»: reuse partner's terms/register). «Вставить в чат ⌘↩» activates the source app
  and pastes (never sends). Drafts kept per partner message while the app runs.
- `MainWindow/HelpViewController.swift`: «Как пользоваться» page (⌘5, menu). Cards animate only on hover
  (all-at-once loops cost 16–24 % CPU on 120 Hz).
- DEBUG render hooks: `TOLK_RENDER_REPLY=dir`, `TOLK_RENDER_POPUP=dir` write PNGs (no screen-recording needed).

## v0.5.0 — models, fallback, profiles, history, documents, status line
- Config: `fallback` (google / apple / none; old `useGoogleFallback` is read and migrated), `profiles` +
  `activeProfileID` — each `GlossaryProfile` has its own rules file and optional model; the engine uses
  `effectiveRulesPath` / `effectiveModel`. Settings: model picker (`*-translate` models from the server),
  fallback picker, profiles editor; menu bar «Профиль: …».
- `AppleTranslationProvider` (Translation framework, macOS 26+, on-device; 15 s timeout).
- History: `TolkCore/History/HistoryStore` (JSONL, 0600, ≤3000) + `Tolk/History/HistoryRecordingEngine`
  decorator per origin (popup/reply/quick/page/image; documents are not recorded) + «История» page.
- Documents: `Tolk/Documents/**` — PDF (text + OCR), Word/RTF/ODT/HTML/TXT/MD, paragraph-by-paragraph,
  pause/resume, export DOCX/RTF/TXT/MD (bilingual option).
- `TranslationEvent.stats(TranslationStats)` before `.finished` (route, first chunk, exact tokens via
  `stream_options.include_usage` → `UsageBox` task-local); `StatusLineView` under translations
  (popup, translate page, reply). `TranslationRunner.onStats`.

## v0.5.2 — tuned for Gemma (default model)
- Translation requests send `seed: 42` (with temperature 0.1): the same text gets the same translation every time
  (Gemma: 3/3 identical with a seed, 3 different without). Notes/alternatives keep variety (no seed).
- `RulesStore.promptBlock(for:target:)` turns every glossary pair to point into the target language
  (the file mixes «en → ru» and «ru → en»; Gemma copied the wrong side otherwise).
- Prompt consistency rules: number format of the target language, no doubled currency, transliterate first names,
  one form of address («Вы»), «Добрый день» → Hello / Hi <Name>; chat tone keeps slang but never adds swearing.
- Measured on ~/Translate/test-corpus (50 Kadam texts): Gemma vs Qwen 21/11/18 (wins/losses/ties);
  Gemma with rules vs without: 26 better, 3 worse, 20 same.

## v0.6.0 — system-wide autocomplete (in the spirit of Cotypist)
- `Sources/Tolk/Autocomplete/`: ghost text after the caret in any app; Tab = next word, → = all, Esc = dismiss.
  Off by default (menu bar → Автодополнение); terminals/IDEs and password fields are excluded.
- Model runs ON THIS MAC (no network: suggestions must land in ~100–300 ms): Homebrew `llama-server`
  on 127.0.0.1:8178, started/stopped by Tolk (`LocalModelServer`), one slot, prompt cache on.
  Default `gemma-4-E4B-it-q4_0.gguf` (Google QAT) in ~/Library/Application Support/Tolk/models.
  The base E4B GGUF drifted into noise; the it model with a raw prompt (no chat template) won.
  Prompt must not end with a space (models jump to digits/dates). Measurements: ~/Translate/test-corpus/autocomplete-eval.md.
- `FocusedField` reads text before the caret and the caret rect via Accessibility (character-before-caret rect
  first: zero-length ranges return whole paragraphs in some apps). `ScreenContext` adds the visible conversation
  (AX first, OCR of the window as fallback; cached, refreshed ≤ every 4 s) at the START of the prompt so the
  llama.cpp KV cache is reused while typing (warm ≈120 ms, after a context change ≈400 ms).
- Extension points (`AutocompleteHooks.swift`, wired in `AutocompleteFeatures.configure`):
  instant providers without the model — `Autocorrect` (NSSpellChecker, skips glossary/adtech slang) and
  `EmojiSuggestions` (`:fire`, `:огонь`); `PromptExtras` — instructions (global, per app, tone, matching glossary
  terms), fresh clipboard, length; `StyleMemory` — opt-in, AES-GCM encrypted local store of sent/accepted phrases
  (key in Keychain), 2–3 similar ones as style examples; «Удалить выученное» wipes file and key.
- Every switch is in Settings and in the menu bar submenu; nothing requires editing tolk.json.

## v0.6.1 — autocomplete tuned on live use
- Electron/WebView fields (Slack, Teams): text and caret read through AX text markers when CFRange attributes
  are missing; every refusal is logged with its step. Ghost text sits on the app's baseline, uses the app's font
  size when AX reports it, is clipped to the field/window, and always draws its leading space.
- Confidence gating: `CompletionClient` asks llama-server for `n_probs`, `AutocompletePrompt.confidentPrefix` cuts the
  suggestion at the first unsure token and never shows half a word. Frequency (menu/Settings): rare 0.6 / normal 0.4 /
  often 0.25 first-token probability. A real word before the caret gets letters appended only at p ≥ 0.8.
  Filters drop invented numbers, markup and header echoes; 3 short few-shot messages lead the prompt.
- Measured (autocomplete-eval.md, rounds 2–3): Gemma 26B on vkbox via Ollama ≈1.35 s and over-confident — kept for
  translation only; 26B on the Mac was rejected by the user (memory/heat).
- Autocorrect is conservative: never changes the first letter, skips brands/slang and words already in the text,
  remembers ignored fixes.
- Debug journal (menu, 1 hour, local only): jsonl + screenshots around the caret on shown/accepted events.
- Settings split into tabs: Перевод · Автодополнение · Общие.

## v0.6.2 — translation for everyday use, sentence cache, checks
- Prompts are neutral (no adtech in the base prompt or notes) with explicit anti-calque guidance per target language;
  profile files carry the domain. A missing profile file falls back to built-in rules in memory (`DefaultRules.home`,
  a copy of `~/Translate/home.md` — re-sync by hand when that file changes). Default model `gemma-translate`,
  default profile `home`.
- Glossary matching (`RulesStore`): Latin terms match as whole words with regular inflections, Cyrillic terms by stem
  plus a short ending; only matching lines are injected.
- Live typing translates only what changed (`IncrementalTranslation.swift`, `UI/LiveTranslation.swift`):
  `IncrementalSession.plan` returns unchanged / full / partial; a partial request sends the changed tail with
  `TranslationContext` (earlier source + its translation). ⌘↩, clearing the field, or a change of language, tone,
  model or config resets the cache. Log line: `incremental: partial kept=3 sent=1 chars=42`. Earlier sentences are
  not revisited when later text changes their meaning — ⌘↩ retranslates everything.
- Post-translation check (`TranslationCheck.swift`): lost links, numbers, times → `TranslationStats.warnings`,
  shown as an orange ⚠ first in the status line.
- Editor pass (`Refine.swift`, `UI/RefineRunner.swift`): optional second call that removes calques; must keep
  greetings and the sentence type; «Вернуть» restores the draft. Costs one more request (≈4–5 s).
- History stores the full text and full translation for partial requests (`HistoryRecordingEngine`).
- First-run screen (`MainWindow/FirstRunView.swift`); not shown on a `--background` start.
- Typing help without the model: the key tap also runs when only `autocorrect` or `autocompleteEmoji` is on
  (`AppDelegate.wantsTypingTap`, `AutocompleteController.modelEnabled = false`): no llama-server, no screen context,
  no style learning; the field is read only after a finished word or an emoji code. Accepting a fix re-reads the
  field and compares app and text; secure input and password managers are never read.
- Tests: `swift run tolk-cli --self-test` (no XCTest in the CLT). New CLI flags: `--rules PATH`, `--context-source`,
  `--context-translation`, `--check TRANSLATION`, `--refine`.
- Measured (`~/Translate/test-corpus`): everyday corpus `verdict-home.md` — texts with calques 17 → 4 of 50;
  work corpus `results-2026-11-10-1122.md` — 50/50, ≈5.9 s per text.

## v0.6.3 — safer autocomplete, server lifecycle, quieter Mac
- Default suggestion model in use: Gemma 4 E2B abliterated Q4_K (`gemma-4-E2B-abl-Q4_K.gguf`, 3.4 GB) — same quality as
  E4B on the 54-case set, ~105 ms per warm suggestion vs ~160–250 ms, 3.6 GB RAM. Comparison: E2B/E4B abliterated and
  Qwen 3.5 4B abliterated, raw prompt and chat template (chat-template E4B scored best, 8/9 shown, but 530 ms; not used).
- Insert safety (`TolkCore/AutocompleteSafety.swift`, `AutocompleteController.verifiedField`): Tab/→ and autocorrect
  re-read the field within 25 ms and insert only if process, element and text before the caret are unchanged;
  otherwise the key passes through. Nothing is read or shown while `IsSecureEventInputEnabled()` or in built-in off
  apps (password managers, terminals, IDEs), which are added to the user's `autocompleteOffApps`.
- AX reads in the key handler run with a time budget (`FocusedField.readQuick`); clipboard is read only when the
  «Буфер обмена» switch is on. Autocorrect no longer rejects a word forever because the user typed past it.
- Server lifecycle (`TolkCore/AutocompleteServerLogic.swift`, `LocalModelServer`): llama-server runs under an `sh`
  wrapper that kills it when Tolk dies (also on kill -9); pid file `~/Library/Application Support/Tolk/llama-server.pid`
  tells our orphan (stopped, restarted) from a foreign process on 8178 (left alone, «порт занят»). Errors are logged and
  shown in Settings and the menu with «Повторить»; automatic restarts after 2, 10, 60 s. No screen snapshots while the
  model is not ready.
- Power saving: «на батарее» options (rare suggestions, no screen OCR, short suggestions; all off by default) and a
  separate switch for screen OCR context (`ScreenContext`).
- Editor pass guard (`RefineGuard` in `Refine.swift`): the edit is dropped if it removes a final «?», changes or drops
  the greeting, or is empty. The edited text is buffered and shown at once (no streaming).
- Self-test: 197 checks.

## v0.6.4 — big translate window, caches, autocomplete healing, review follow-ups
- Translate page hints panel (`UI/TranslationHintsPanel.swift`): 3rd column ≥1000 pt wide, below the translation when
  narrower. Cards: check warnings, footnotes, back-translation, word alternatives, add to glossary, editor diff.
  Shared with the popup via `UI/HintsKit.swift` (`HintsSettings`, `HintTask`, `BackTranslationJob`, `NoteRow`,
  `GlossaryFormView`); same `UserDefaults` switches (`tolk.popup.notes`, `tolk.popup.back`). Requests start 1.5 s after
  a finished translation, any typing cancels them, at most two at once (Ollama has two slots).
- Offscreen render for review: `TOLK_HINTS_SHOT=<dir> .build/debug/Tolk --background` (`TranslateHintsDemo.swift`,
  never ordered on screen).
- Engine for the big window (`Engine/BigWindowTools.swift`, `Engine/SentencePairs.swift`), not yet in the UI:
  `SentencePairing.pairs` (no model), `sentenceVariants`, `rewrite` (shorter/softer/firmer/simpler/formal/informal,
  guarded by `TranslationCheck`, question/greeting and pronoun checks), `translateReply` (detects the partner's
  language), `explain` (meaning, tone, ≤5 terms). CLI: `--pairs`, `--variants`, `--rewrite`, `--reply-to`, `--explain`.
- Big-window UI (page «Перевод»): sentence pairs (hover highlights the pair in both panes, unsure pairs paler; no model),
  click / context menu on a translated sentence → «Варианты предложения» card; rewrite row (Короче/Мягче/Твёрже/Проще,
  ты|Вы; folds into a menu when narrow) with «Правка» before/after card and «Вернуть»; reply mode («Перевод | Ответ»:
  partner's message + its translation on top, my answer, reply translated via `replyRequest`); «Что он имел в виду» card
  (meaning, tone badge, terms); glossary terms underlined in the translation (`RulesStore.glossaryHits` + `marks`);
  back-translation highlights only meaning differences (`BackDiff`: numbers, negations, names, glossary terms);
  «Последние» popover from `HistoryStore` (no request); a file dropped on the page opens «Документы».
  All model requests are button-started with a cancel; at most two at once (`slotAvailable`, background hints give way).
  `TranslationEngine` got the extras as protocol requirements (defaults throw; `HistoryRecordingEngine` forwards).
  Offscreen render: `TOLK_HINTS_SHOT=<dir>` writes translate-{wide,narrow}-{light,dark}-{1-hints,2-pair-hover,3-variants,
  4-rewrite,4b-rewrite-rejected,5-reply,6-explain}.png and recent-{light,dark}.png.

## Autocomplete: healing, prefill, OCR economy
- Token healing (`TolkCore/AutocompleteHealing.swift`, switch `AutocompletePrompt.useHealing`): the half-typed word is cut
  off the prompt and `CompletionClient` sends a GBNF `grammar` forcing the reply to start with it; the forced letters are
  stripped again and the first free token's probability is renormalised over grammar-consistent alternatives. Mid-word
  endings: 0 → 9 of 15 right (E2B). Cost ≈ +50 ms per request (grammar sampling).
- Chat prefill (switch `AutocompletePrompt.useChatPrefill`, only when `/props` shows a Gemma 4 template, see
  `CompletionClient.probeFormat`): rules, examples and conversation in the user turn, the typed text is the start of the
  model turn, no thought block. Per keystroke llama-server re-evaluates 1–6 tokens. Other models keep the raw prompt.
- Screen context (`ScreenContext`, `TolkCore/ContextRefresh.swift`, switch `ScreenContext.smartRefresh`): the OCR'd region
  (without the input field) is shrunk to a 32×32 grayscale signature; Vision runs only if ≥ 0.4 % of cells changed.
  The screen is looked at on events (other window, field emptied = sent, scroll) after 1.5 s, otherwise every 15 s.
- Numbers and the NSSpellChecker comparison: side-session notes `ac-healing-report.md`.

## v0.6.4 integration notes
- Translation cache (`Engine/TranslationCache.swift`): in-memory LRU (200 entries / 2 MB / 24 h) keyed by SHA-256 of the
  final system prompt + text + model, so rules, glossary, tone, thread context and profile changes miss automatically;
  only finished main-model translations are stored; `TranslationRequest.bypassCache`; `TranslationStats.fromCache` →
  status line «из кеша». Notes have their own cache. Variants/rewrite/explain are never cached.
- Thread memory (`Engine/ThreadMemory.swift`) is wired into the popup: short texts (≤20 words) from the same app within
  5 min get the last ≤3 turns as context; the same text is never its own context (keeps the cache key stable).
- Calques (`Engine/CalqueDetector.swift`, 48 entries) go to warnings as «калька: …»; the editor answers `OK` when
  nothing needs fixing. Entity masking (`Engine/EntityMasker.swift`) exists but is OFF: Gemma kept every URL/macro on 24
  adtech texts by itself and masking hurt phrasing. Time zones without the model: `Engine/TimezoneConverter.swift`.
- `RulesFingerprint` is part of the live-typing sentence cache key (`UI/LiveTranslation.swift`).
- Autocomplete statistics (`autocomplete-stats.json`, numbers only): Settings → Автодополнение and the menu bar;
  `tolk-cli --ac-stats`.
- Measured on vkbox (2026-11-10): num_ctx 8192 vs 32768 — generation ≈26 vs ≈22 tok/s, first token the same (~1.1 s).
  Ollama reloads the model (~30 s) whenever a request asks for another num_ctx, so change it only in the Modelfile.
