# Tolk — архитектура

Версия 0.7.0. Этот файл начинается с актуального обзора. Ниже, в разделе «История и журнал версий», идут записи по версиям от 0.3 до 0.7.0. Установка — в [SETUP.md](SETUP.md), работа с приложением — в [docs/USER-GUIDE.md](docs/USER-GUIDE.md).

## Обзор

### Цели

- Личный переводчик для macOS «как DeepL, но на своей модели»: двойное ⌘C в любом приложении, перевод рядом с курсором, потоковый вывод.
- Рабочая переписка (adtech, RU ↔ EN) и бытовая (RU / UK / EN). Перевод с правилами и глоссарием, ответ собеседнику на его языке.
- Помощь при наборе: автодополнение, «Перевод при наборе», исправление опечаток и раскладки.
- Приватность: перевод идёт только на сервер пользователя, подсказки считаются на Mac, в облако по умолчанию ничего не уходит. Google — запасной путь по выбору.
- Сборка без Xcode: Command Line Tools со Swift 6.2, режим языка Swift 5, macOS 14+.

### Схема

```
 Mac (Tolk.app)                                          Сервер модели (Ollama :11434, 2 слота)
 ┌─────────────────────────────────────────────┐  HTTP  ┌──────────────────────────────────────┐
 │ Input: двойное ⌘C, горячие клавиши           │ ─────▶ │ gemma-translate (Gemma 4 26B MoE,     │
 │ UI: popup, «Ответить», большое окно          │ ◀───── │   num_ctx 8192)                       │
 │ TolkCore: промпты, правила, проверки, кеши   │  поток └──────────────────────────────────────┘
 │ Autocomplete: llama-server 127.0.0.1:8178    │
 │   Gemma 4 E2B abliterated Q4_K (Metal)       │  нет сервера → Google / Apple Translation /
 └─────────────────────────────────────────────┘  ничего (в «Переводе при наборе» — тишина)
```

Запрос перевода идёт по OpenAI-совместимому `/v1/chat/completions` с `reasoning_effort: "none"`, `temperature: 0.1`, `seed: 42`. Сноски, варианты и прочие JSON-запросы — те же маршруты с другими промптами. Одновременно к модели идут не больше двух запросов.

### Цели пакета (`Package.swift`)

| Цель | Что это | Зависимости |
|---|---|---|
| `TolkCore` | Движок без AppKit: модели языков и запросов, провайдеры, промпты, правила и глоссарий, проверки, кеши, история, чистая логика автодополнения, самотест | — |
| `Tolk` | Приложение в строке меню: ввод, окна, автодополнение, OCR, документы | `TolkCore` |
| `tolk-cli` | Инструмент разработчика: перевод из терминала, все режимы движка, самотест, корпуса | `TolkCore` |

### Подсистемы и файлы

| Подсистема | Файлы |
|---|---|
| Контракты (языки, запрос, события, настройки `TolkConfig`) | `TolkCore/Contracts.swift` |
| Перевод: провайдеры и маршрутизация | `Engine/DefaultTranslationEngine.swift`, `OllamaProvider.swift`, `GoogleProvider.swift`, `AppleTranslationProvider.swift`, `LanguageDetector.swift`, `TolkError.swift` |
| Промпты, правила, глоссарий | `Engine/Prompt.swift`, `RulesStore.swift`, `DefaultRules.swift`, `RulesFingerprint.swift`, `Glossary/*` |
| Проверки и страховки | `Engine/TranslationCheck.swift`, `CalqueDetector.swift`, `Refine.swift` (`RefineGuard`), `BackDiff.swift`, `EntityMasker.swift` (выключен) |
| Кеши и память | `Engine/TranslationCache.swift`, `IncrementalTranslation.swift`, `ThreadMemory.swift` |
| Сноски и инструменты большого окна | `Engine/NotesProvider.swift`, `BigWindowTools.swift`, `SentencePairs.swift`, `ReplyChips.swift`, `PopupHandoff.swift` |
| Без модели | `Engine/LayoutFix.swift`, `TimezoneConverter.swift` |
| История | `TolkCore/History/HistoryStore.swift`, `Tolk/History/*` |
| Ввод и быстрые действия | `Tolk/Input/DoubleCopyMonitor.swift`, `Tolk/Actions/*` (`HotKey`, `QuickAction*`, `ClipboardPaste`, `SpellCheckOracle`), `TolkCore/HotKeyRules.swift`, `CaptureFocus.swift` |
| Всплывающее окно и «Ответить» | `Tolk/UI/TranslationPopupController.swift`, `ReplyPanelController.swift`, `StatusLineView.swift`, `HintsKit.swift`, `RefineRunner.swift`, `LiveTranslation.swift` |
| Большое окно | `Tolk/MainWindow/*` (`TranslatePageViewController`, `ComposePanel`, `RewriteBar`, `SettingsViewController`, `HelpViewController`, `ACStatsView`), `UI/TranslationHintsPanel.swift` |
| Глоссарий (редактор) | `Tolk/Glossary/*`, `TolkCore/Glossary/*` |
| Фото и экран | `Tolk/ImageTranslate/*` (Vision OCR, `ScreenCaptureController`) |
| Документы | `Tolk/Documents/*` |
| Автодополнение | `Tolk/Autocomplete/*` (`AutocompleteController`, `FocusedField`, `ScreenContext`, `AutocompletePrompt`, `LocalModelServer`, `Autocorrect`, `EmojiSuggestions`, `StyleMemory`, `SuggestionJournal`), `TolkCore/AutocompleteSafety.swift`, `AutocompleteTuning.swift`, `AutocompleteHealing.swift`, `AutocompleteServerLogic.swift`, `AutocompleteStats.swift`, `ContextRefresh.swift` |
| «Перевод при наборе» | `Tolk/TypeTranslate/*`, `TolkCore/TypeTranslate.swift` |
| Диагностика | `Tolk/Diagnostics/Diagnostics.swift` (`~/Library/Logs/Tolk`) |
| Сборка и установка | `scripts/*` (`build-app.sh`, `install.sh`, `make-dmg.sh`, `make-signing-cert.sh`, `make-icon.sh`), `Resources/*`, `VERSION` |

Правило версий: `VERSION` — единственное место. `build-app.sh` пишет его в `CFBundleShortVersionString`, число коммитов — в `CFBundleVersion`, короткий хеш (с `-dirty` при незакоммиченных изменениях) — в `TolkGitCommit`. Для релиза: поднять `VERSION`, закоммитить, поставить тег `vX.Y.Z`, собрать и установить.

### Модели и ключевые замеры

| Что | Значение |
|---|---|
| Перевод | `gemma-translate` (Gemma 4 26B MoE, 128 экспертов, 8 активных, около 4B активных параметров), Q4_K_M. `qwen-translate` (Qwen 3.6 35B-A3B) — запас, выбирается в настройках |
| Скорость перевода | Видеокарта 6 ГБ: около 22 ток/с с `num_ctx 32768`, около 26 с `num_ctx 8192` (+15–20 %), первое слово около 1,1 с. Видеокарта 12 ГБ (Windows-ПК друга): около 55 ток/с |
| Перезагрузка модели | Запрос с другим `num_ctx` перезагружает модель (около 30 с). Tolk `num_ctx` не передаёт; менять его только в `Modelfile` |
| Слоты Ollama | `OLLAMA_NUM_PARALLEL=2`: при шести параллельных запросах медианное ожидание 5,5 с против 8,6 с с одним слотом. Четыре слота хуже |
| Корпус «работа» (50 текстов adtech) | 50 из 50, около 5,9 с на текст. Gemma против Qwen: 21 / 11 / 18 (лучше / хуже / одинаково) |
| Корпус «дом» (50 текстов RU / UK / EN) | Текстов с кальками 17 → 4 |
| Корпус ловушек (321 текст) | Автопроверка 299/321 → 313/321 на `gemma-translate`; `qwen-translate` 290/321 с тем же промптом |
| Модель подсказок | Gemma 4 E2B abliterated Q4_K (3,4 ГБ, около 3,6 ГБ памяти), `llama-server -c 4096 -ngl 99 -fa on -np 1`; тёплая подсказка около 105 мс против 160–250 мс у E4B |
| Подсказки при наборе | Набор из 54 случаев: правильная подсказка появляется в 23 случаях при проходе по буквам (было 14); окончания слов посреди слова: 0 → 9 из 15 с «token healing» |
| Отвергнуто | Gemma 26B для подсказок на Mac (около 15 ГБ, нагрев) и на сервере (около 1,35–1,4 с, переоценивает уверенность) |

Подробности и таблицы сравнения моделей — в журнале версий ниже и в замерах `~/Translate/test-corpus`.

### Как это проверяется

- **Самотест** `swift run tolk-cli --self-test`: 777 проверок (на версии 0.7.0) без модели и сети. В Command Line Tools нет XCTest, поэтому тесты свои: `TolkCore/SelfTest*.swift`. Покрывают глоссарий, промпты, проверки, кеши, разбор JSON, страховки редактора и переписывания, логику безопасности и сервера автодополнения, пары предложений, раскладку, часовые пояса, ловушки.
- **Корпуса** на живой модели: `tolk-cli --trap-corpus FILE [--model M] [--rules P] [--trap-out J] [--trap-only ids|types]` (321 текст), рабочий и бытовой корпуса в `~/Translate/test-corpus` (замеры «было / стало»), набор из 54 случаев для автодополнения (`autocomplete-eval.md`).
- **`tolk-cli`** гоняет каждый режим движка на модели: `--rewrite`, `--variants`, `--variants-all`, `--compose`, `--reply-to`, `--explain`, `--pairs`, `--check`, `--refine`, `--type-sim`, `--tz`, `--ac-stats` и другие (`--help`).
- **Офлайн-отрисовка интерфейса** в PNG без показа окон на экране (отладочная сборка): `TOLK_RENDER_POPUP=dir`, `TOLK_RENDER_REPLY=dir`, `TOLK_HINTS_SHOT=dir .build/debug/Tolk --background`, `TOLK_MAIN_SHOT`, `TOLK_AC_STATS_SHOT`, `TOLK_TYPE_TRANSLATE_SHOT`.
- **Правило проекта:** проверки «невидимые», без окон на экране, смены фокуса, синтетических нажатий и изменения буфера. Всё, что так не проверить (реальные щелчки, Tab в чужих полях), помечается «не проверено» и проверяется вживую.
- **Дымового прогона** отдельным скриптом нет.

### Как ведётся работа

Координатор держит архитектуру, делит работу между параллельными сессиями (у каждой свой worktree и свои файлы), сводит ветки, прогоняет самотест и только после согласия пользователя коммитит и ставит сборку.

## История и журнал версий

Ниже — прежняя шапка файла и записи по версиям. Записи не переписывались.

### Первоначальная постановка (v0.1–v0.2)

Двойное ⌘C → окно рядом с курсором со стримингом перевода от Qwen (`qwen-translate` на сервере Ollama в домашней сети, OpenAI-совместимый `/v1`, `reasoning_effort: "none"`), правила и глоссарий из `~/Translate/rules.md`, запасной Google при выключенном сервере. С версии 0.5.2 основная модель — Gemma (`gemma-translate`), Qwen остаётся запасной.

Сборка: `swift build`, Swift 6.2 CLT, режим языка Swift 5.

### Распределение файлов между сессиями (v0.1–v0.3, для истории)

Параллельные сессии правили только свои файлы и ничего не коммитили.

| Область | Файлы | Владелец |
|---|---|---|
| Контракты | `Sources/TolkCore/Contracts.swift` | координатор (менять по согласованию) |
| Движок | `Sources/TolkCore/Engine/**`, `Sources/tolk-cli/**` | сессия движка |
| Ввод и упаковка | `Sources/Tolk/Input/**`, `scripts/**`, `Resources/**` | сессия ввода |
| Интерфейс | `Sources/Tolk/UI/**` | сессия интерфейса |
| Связка | `Sources/Tolk/AppDelegate.swift`, `main.swift`, `Package.swift` | координатор |

v0.3 (полное приложение):

| Область | Файлы | Владелец |
|---|---|---|
| Главное окно, Dock, страница перевода, настройки, иконка | `Sources/Tolk/MainWindow/**`, `Sources/Tolk/UI/InputWindowController.swift`, `Resources/**`, `scripts/**` | сессия главного окна |
| Редактор глоссария | `Sources/Tolk/Glossary/**`, `Sources/TolkCore/Glossary/**` | сессия глоссария |
| Перевод фото и скриншотов (OCR) | `Sources/Tolk/ImageTranslate/**` | сессия картинок |
| Popup, движок, контракты, связка | `UI/TranslationPopupController.swift`, `UI/UIShared.swift`, `TolkCore/Engine/**`, `Contracts.swift`, `AppDelegate.swift` | координатор |

### Модели Ollama — особенности (v0.5)
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

### Versioning
- `VERSION` (e.g. `0.3.1`) is the only place to change the version. `scripts/build-app.sh` writes it to
  `CFBundleShortVersionString`, sets `CFBundleVersion` = commit count and `TolkGitCommit` = short hash
  (`-dirty` if there were uncommitted changes). Settings → «О программе» and crash reports show all three.
- Each release: bump `VERSION`, commit, `git tag vX.Y.Z`, then build/install. Tags: v0.1 … v0.3.1.

### v0.4.0 — reply mode and in-app help
- `UI/ReplyPanelController.swift`: «Ответ» window from the popup («Ответить» / R). Partner's message (full, scrolls
  when long) + reply input + live translation into the partner's language with `TranslationRequest.replyTo`
  (prompt «Conversation context»: reuse partner's terms/register). «Вставить в чат ⌘↩» activates the source app
  and pastes (never sends). Drafts kept per partner message while the app runs.
- `MainWindow/HelpViewController.swift`: «Как пользоваться» page (now ⌘7, menu). Cards animate only on hover
  (all-at-once loops cost 16–24 % CPU on 120 Hz).
- DEBUG render hooks: `TOLK_RENDER_REPLY=dir`, `TOLK_RENDER_POPUP=dir` write PNGs (no screen-recording needed).

### v0.5.0 — models, fallback, profiles, history, documents, status line
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

### v0.5.2 — tuned for Gemma (default model)
- Translation requests send `seed: 42` (with temperature 0.1): the same text gets the same translation every time
  (Gemma: 3/3 identical with a seed, 3 different without). Notes/alternatives keep variety (no seed).
- `RulesStore.promptBlock(for:target:)` turns every glossary pair to point into the target language
  (the file mixes «en → ru» and «ru → en»; Gemma copied the wrong side otherwise).
- Prompt consistency rules: number format of the target language, no doubled currency, transliterate first names,
  one form of address («Вы»), «Добрый день» → Hello / Hi <Name>; chat tone keeps slang but never adds swearing.
- Measured on ~/Translate/test-corpus (50 Kadam texts): Gemma vs Qwen 21/11/18 (wins/losses/ties);
  Gemma with rules vs without: 26 better, 3 worse, 20 same.

### v0.6.0 — system-wide autocomplete (in the spirit of Cotypist)
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

### v0.6.1 — autocomplete tuned on live use
- Electron/WebView fields (Slack, Teams): text and caret read through AX text markers when CFRange attributes
  are missing; every refusal is logged with its step. Ghost text sits on the app's baseline, uses the app's font
  size when AX reports it, is clipped to the field/window, and always draws its leading space.
- Confidence gating: `CompletionClient` asks llama-server for `n_probs`, `AutocompletePrompt.confidentPrefix` cuts the
  suggestion at the first unsure token and never shows half a word. Frequency (menu/Settings): rare 0.6 / normal 0.4 /
  often 0.25 first-token probability. A real word before the caret gets letters appended only at p ≥ 0.8.
  Filters drop invented numbers, markup and header echoes; 3 short few-shot messages lead the prompt.
- Measured (autocomplete-eval.md, rounds 2–3): Gemma 26B on the home server via Ollama ≈1.35 s and over-confident — kept for
  translation only; 26B on the Mac was rejected by the user (memory/heat).
- Autocorrect is conservative: never changes the first letter, skips brands/slang and words already in the text,
  remembers ignored fixes.
- Debug journal (menu, 1 hour, local only): jsonl + screenshots around the caret on shown/accepted events.
- Settings split into tabs: Перевод · Автодополнение · Общие.

### v0.6.2 — translation for everyday use, sentence cache, checks
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

### v0.6.3 — safer autocomplete, server lifecycle, quieter Mac
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

### v0.6.4 — big translate window, caches, autocomplete healing, review follow-ups
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

### Autocomplete: healing, prefill, OCR economy
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

### v0.6.4 integration notes
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
- Measured on the home server (2026-11-10): num_ctx 8192 vs 32768 — generation ≈26 vs ≈22 tok/s, first token the same (~1.1 s).
  Ollama reloads the model (~30 s) whenever a request asks for another num_ctx, so change it only in the Modelfile.

### v0.6.5 — «Перевод при наборе» (type in your language, insert the translation)
- ⌃⌥R toggles the mode per app (`TolkConfig.typeTranslateApps`, optional `typeTranslateAuto` when the partner's last
  message on screen is in another language; off by default). Also in the menu bar and Settings → Автодополнение.
- After a 500 ms pause the whole field text is translated into the partner's language (`TolkCore/TypeTranslate.swift`:
  partner message + language from `ScreenContext`, else `secondaryLanguage`) with `replyTo`, app tone and thread
  context; the engine for this mode has no fallback (server down → silence, nothing goes to Google).
- `Sources/Tolk/TypeTranslate/`: grey line under the field (≤3 lines, «→ EN», «Tab — вставить, Esc — оставить»).
  Tab re-reads the field (process, element, full text), selects all via `AXSelectedTextRange` and pastes through the
  shared `Actions/ClipboardPaste.swift` (pasteboard restored, transient types) so the app's ⌘Z works. Enter is never
  intercepted. Same exclusions as autocomplete; autocomplete stays silent in apps where the mode is on.
- CLI: `tolk-cli --type-sim "partner" "my text"`. Self-test: 526 checks.

### v0.6.6 — focus, wording, own windows, my previous messages
- Screen capture (`TolkCore/CaptureFocus.swift`): result goes to the main window only if Tolk was the active app when
  ⌥⇧S was pressed (then Tolk stays active); otherwise the popup at the area and focus returns to the previous app;
  ⌘Tab during the selection leaves focus alone.
- Autocomplete, typo fixes, emoji and «Перевод при наборе» stay silent while the key window is Tolk's own
  (`AutocompleteSafety.focusIsInOwnWindow`: popup and reply panels do not activate Tolk, so the front app is not enough).
- Typo-fix Tab: invisible tails after the caret (zero-width, U+FFFC, BOM…) count as blank (`isBlankTail`); instant
  suggestions are re-checked 120/350 ms after showing and hidden early if the field no longer fits.
- Prompt: up to 3 of my messages sent in the same app within 15 min (`RecentMessages`, from `StyleMemory`, only when
  style learning is on) before the screen conversation.
- Wording unified (Копировать, Письмо, Отмена, one fallback notice, no raw errors); reply window no longer animates per
  token. Self-test: 555 checks.

### v0.6.7 — autocomplete like Cotypist
- A suggestion is requested on every keystroke: 20 ms pause (60 ms when keys come < 110 ms apart, so the single
  llama-server slot does not queue), stale requests are cancelled. Measured on the 54-case set by replaying typing
  letter by letter: cases where a right suggestion appeared 14 → 23 (+64 %) at the same first-word precision (61–63 %).
- Thresholds (`TolkCore/AutocompleteTuning.swift`): rare 0.6/0.35, normal 0.5/0.35, often 0.3/0.3 — below 0.5 only
  wrong suggestions are added.
- Word choice (off / medium / strong): `logit_bias` towards the first tokens of the user's frequent words (accepted
  suggestions + sent messages, only with style learning). No measurable gain on the case set; kept as an option.
- Style memory records only messages with an accepted suggestion by default (option: record everything).
- ⌥Tab is a plain Tab; Esc pauses suggestions in this field until the field or app changes. No suggestions in search
  fields, address bars, table cells and small or login/email/IBAN fields.
- Studied: KeyType and TabType (MIT): both use raw prompts + token healing and request per keystroke; notes in the
  side-session report. Self-test: 575 checks.

### Translation variants (whole text)
- `translationVariants(source:translation:from:to:tone:replyTo:)` (`Engine/BigWindowTools.swift`): one JSON request,
  ≤3 `TranslationVariant { text, label, reason }`, label and reason in the user's language; variants that lose numbers,
  links, times, a question or the greeting, and near-copies (≥80 % same words) are dropped. 9–15 s per request.
- Big window: «Варианты перевода» card (button only; word diff against the current translation, «Взять» / «Вернуть»).
  Popup: «Варианты» in the header opens the big window with the same text, tone and chat context (translation comes
  from the cache) and starts the request. CLI: `--variants-all`. Self-test: 587 checks.

### v0.6.8 — tone modes, compose, layout fix, final pass, tails
- Rewrite modes «По-деловому» (`professional`) and «Прямо» (`direct`): same guard as the others, plus no new numbers.
  The row folds into «Ещё ▾» / «Переписать ▾» on narrow cards (`RewriteBar`).
- «Составить» page mode (`MainWindow/ComposePanel.swift`, `compose(points:tone:to:partnerMessage:)`): points in the
  user's language → a finished message (Нейтрально / По-деловому / Прямо / Дружелюбно) + back-translation; warns when a
  number/time/date from the points is missing or a new one appears. ~25–30 s per request; tones are still too similar.
- ⌃⌥L «Исправить раскладку» (`Engine/LayoutFix.swift`, `Actions/SpellCheckOracle.swift`): RU/UK ↔ EN by word, no model.
- Final pass on the translate page: after a 2.5 s pause, ≤600 chars, >1 sentence and partial translations in this
  session, the whole text is translated once; replaced only if different (`incremental: final pass changed=…`).
- «↻ заново» on a cached result (popup and page, ⌘R on the page) sends `bypassCache`.
- Time zones in the popup and in the «Проверка» card (`TimezoneConverter`); thread memory in «Ответить».
- One source for server/fallback texts (`ServerText`) and Esc hints (`EscText`); hotkeys are editable in Settings →
  Общие (quick actions and «Перевод при наборе»); `TOLK_RENDER_POPUP` renders off-screen now (never shown).
- Home server: `gemma-translate` recreated with num_ctx 8192 (old one kept as `gemma-translate-32k`). Self-test: 690 checks.

### v0.6.9 — reply chips, honest tones
- «Ответить» window: «Подтвердить», «Смотрим», «Детали?», «Созвон?», «Отказать» (⌘1…⌘5, `Engine/ReplyChips.swift`):
  `compose` with the partner's message, app tone and thread memory writes the reply in the user's language, then the
  normal translation runs. Hidden while the partner message is empty or the user types. ~5.6 s per chip.
- Tones (`ExtrasPrompt`): meta-instructions about tone steer style and never become phrases; no new entities,
  greetings or stronger judgements (checked: new numbers, greeting without one in the source, 9 entity groups,
  meta-phrase leaks). «Added something» 13/48 → 0/48 on 12 examples × 4 tones; tones still converge on short points.
- Compose back-translation is a separate request (`composeBackTranslation`): the message shows in 2–6 s.
- `TOLK_RENDER_REPLY` renders off-screen (`ReplyDemo`). Self-test: 717 checks.

### v0.7.0 — trap corpus, live-run fixes
- Trap corpus (321 business/adtech texts: 81 hand-written + 240 synthetic, case U0 = the user's real Slack message;
  file in side-session notes `trap-corpus/full.json`): `tolk-cli --trap-corpus FILE [--model M] [--rules P]
  [--trap-out J] [--trap-only ids|types]`. Auto-check 299/321 → 313/321 on gemma-translate; qwen-translate 290/321
  with the same prompt (weaker on jargon), so Gemma stays.
- Prompt rules RU→EN (direction «убрать от нас / подливать нам» → «stop sending us / from the traffic you send us»,
  лить/лив/сабы/чисто, «до выяснения», «вынуждены уведомить», net-30, «в дальнейшем») and EN→RU (please advise,
  please note, moving forward, per our call, circle back, on your end, «we» stays «мы»); +12 calques; «14-day» and
  «net-N» are not IDs in `TranslationCheck`.
- Live-run fixes: popup → big window keeps tone, languages and context (translation comes from the cache);
  ⌃⌥L maps punctuation of the other layout and fixes short words by sentence context; truncated buttons fixed;
  «Перевод при наборе» reads NSTextView-based fields (TextEdit) and logs every early exit; sidebar click; per-period
  median latency in the statistics. Self-test: 777 checks.

- Style memory key moved from the Keychain to `~/Library/Application Support/Tolk/style.key` (0600): with a self-made
  certificate the Keychain tied «Always Allow» to the exact build, so every rebuild asked for the password. An old
  Keychain key is read once, moved to the file and deleted; a denied read keeps it and pauses style memory instead of
  replacing the key (which used to make style.db unreadable).

## v0.7.1 — hardening and docs
- Reliability audit (~25 fixes): crashes (recursion in `LanguageDetector`, JSON slicing in `NotesProvider`, bad dates in
  `HistoryStore`, AX rectangles, no screens), hangs (`ChunkedTranslator.splitLong`, AX calls without a timeout),
  endless spinners on the image page, races (documents, `LocalModelServer`, `OllamaProvider`), data loss (one bad field
  no longer resets tolk.json; unreadable files are copied to `.corrupt`, never overwritten).
- Two Tolk instances no longer fight over llama-server: the pid record stores the owner; a live foreign Tolk's server is
  left alone. A second Tolk (also a debug binary) activates the first and exits.
- `TOLK_SMOKE=1 .build/debug/Tolk --background`: creates every controller, calls setters and callbacks before and after
  view load, exits 0; touches no user files, no autocomplete, no alerts.
- Default suggestion model is `gemma-4-E2B-abl-Q4_K.gguf`; model descriptions and provider labels match the measurements.
- Docs: README.md, SETUP.md (0.7), docs/USER-GUIDE.md, PROJECT-OVERVIEW.md, in-app help. Self-test: 802 checks.

## v0.7.2 — windows and focus, translation quality review
- Windows: the main window really comes to front (status menu, hotkey, popup, Dock / Finder reopen); closing the last
  window returns focus to the previous app; reply insert pastes only when the chat app became frontmost; area capture
  no longer hides the main window (`AppPresence.bringToFront`, non-activating overlay panel).
- Prompt: phrase rules found on the trap corpus are no longer always in the system prompt. `PhraseRules` sends a rule
  only when its trigger is in the source text (they bled into unrelated sentences: «до завершения проверки» came out
  as «until this is clarified»). The plain prompt is half as long (5.1k → 2.5k characters).
- Glossary: a pair written «русское → English» is one-way (`RulesStore.oriented`): turned around it put chat slang
  into formal Russian letters. Slang renderings only for a casual source; chat tone no longer adds slang that is not
  in the original («let me know» → «дай знать», not «маякни»).
- `ChatHeaderKeeper`: Telegram headers «Name, [date, time]:» are restored verbatim after translation.
- Context: the home model runs with 8192 tokens; `chunkLimit` 6000 → 5000 and the continuation tails 3000 → 2000
  characters so the worst case fits (it could push the rules out of the context).
- Compose tones (neutral / professional / direct / friendly) give different texts; «Перевод при наборе» ignores
  interface captions when it looks for the partner's language.
- Measured on gemma-translate: trap corpus 318/321 (was 315), fresh sets 53/60 and 8/9; test sets in
  `~/Translate/test-corpus/`. Self-test: 837 checks.

## v0.7.3 — live pass over the installed app
- Regression of 0.7.2 fixed: «Составить» and the quick-reply chips answered «недоступно для этого движка» —
  `DefaultTranslationEngine.compose` had gained a parameter and no longer satisfied the protocol requirement, so the
  protocol's default was called. The exact witness is back; a self-test calls `compose` through the protocol.
- The main window no longer resizes itself (it could grow past the screen edge): toolbar and header rows of
  «Документы», «Фото и скриншоты» and «Составить» shrink instead (popup titles truncate, captions drop out).
- Translate page at narrow widths: the mode switch is not clipped, the «из кеша · заново» status stays on one line.
- «Ответ»: a foreign text carried over from a translation becomes the partner's message, not «my answer».
- ⌘V right after choosing «Фото и скриншоты» in the sidebar pastes the picture (`MainWindowController.paste`).

## v0.7.4 — autocomplete: a suggestion when you stop and wait
- Patient second look: when a request ends empty only because of the confidence bar and the caret stays put for
  `AutocompleteTuning.patientDelayMs`, the continuation is shown with relaxed bars (`patientThresholds`: first 0.08,
  next 0.2; not in «редко»). On 40 mid-sentence stops (`~/Translate/test-corpus/ac/midsentence-40.txt`, full live
  prompt): 28 → 38 shown; the two left are wrong word endings, correctly silent.
- A single typed letter is completed when the model is nearly certain (p ≥ 0.8): «как е» + «сть».
- The log says why a request was dropped or came back empty (`no request — …`, `empty suggestion … p1= need= patient=`).
- Dev: `TOLK_AC_EVAL=cases.txt [TOLK_AC_FULL=1] .build/debug/Tolk` runs cases through the live pipeline (`ACEval`).

## v0.7.5 — autocomplete: word endings
- `AutocompleteHealing.strip`: when the token that finishes the typed fragment was not among the reported
  alternatives, it kept its raw probability (~0) and correct endings were cut as "unsure" («дост» → «упа»,
  «каче» → «ства»). It is now weighed against the consistent alternatives; `n_probs` 20 → 100 for such requests.
  `~/Translate/test-corpus/ac/endings-30.txt` (ending must fit the grammar of the sentence): 24 → 28 shown, 22 right.
- Model check on the same sets (2026-11-11): E2B-abl 28/30 shown, 22 right, 39/40 mid-sentence; E4B-abl 23/30,
  13 right, 36/40 and twice as slow. E2B stays.

## v0.7.6 — live pass in web fields
- Second attempt for word endings: when the healed answer is not a word («каче» + «р.»), the request is repeated with
  the fragment left in the prompt as typed. `endings-30`: 28 → 30 shown, 24 right. A healed token with no reported
  alternative to weigh against is capped at 0.5 (it came out as 1.0 and counted as "sure").
- Caret unknown: Chrome `<textarea>` and plain `contenteditable` report no character rectangles (checked with an AX
  probe: `AXBoundsForRange` and the marker variant both return empty rects; lines are hard lines only, no font).
  `FocusedField.caretApprox` → `GhostTextPanel.bubble`: the suggestion is a readable bubble in the field's bottom-left
  corner instead of invisible ghost text over the neighbours; plain contenteditable used to get nothing at all.
- Checked live on a Chromium stand (`~/Translate/test-corpus/live/stand.html`): suggestions 7/7 at pauses, patient
  second look, Tab acceptance; Documents: drag-and-drop from Finder, translation, «Сохранить как…» (docx).

## v0.7.7 — the bubble sits at the caret
- `CaretLocator`: when the app does not report the caret (`FocusedField.caretApprox`), a snapshot of the field is
  recognized (Vision, no language correction) while the model thinks, and the lowest line that ends with the last typed
  characters gives the caret: its right edge. The bubble then appears right after the caret; when the text is not
  found (or screen recording is not allowed) it stays in the field's corner. Checked on the stand in `<textarea>`
  (also on a wrapped second line) and in plain `contenteditable`. Log: `ax=ocr markers fieldCorner …`.


## v0.8.0 — settings you can run the app from, one look for every screen

- **Settings page rebuilt** (`Sources/Tolk/Settings/`): six tabs — Перевод, Автодополнение, Модели, Статистика, Журнал,
  Общие. Cards in a `MasonryLayout` (1–3 columns by window width, `minColumn` 340 pt) instead of the fixed-width
  grouped `Form`. Every control has a hint that says what happens in the current position (`SToggle.offHint`,
  `SChoice.Option.effect`) and, where it helps, an example tile (`SExample`). The header shows only what is wrong
  (server, suggestion model, Accessibility, Screen Recording) or one green «Всё работает».
- **Shared look** (`TolkStyle` in `SettingsKit.swift`): card radius 12, control radius 8, 0.5 pt hairline, card fill
  `nsCard`, grey tiles, capsule pills. Applied to the popup (the translation now sits on a card), reply panel, hints
  panel, history, glossary, documents, image page, help.
- **New settings** (`TolkConfig`): `autocompletePatient` + `autocompletePatientDelay` (was a constant 650 ms),
  `autocompleteCaretBubble`, `verboseLog`, `keepWarmMinutes` (was a constant 15). Plus: add an app to «Где не
  подсказывать», instruction presets (chips), Screen Recording permission row, «Данные на диске» (paths and sizes),
  «Вернуть как было» (reset tuning to measured defaults).
- **Models without a terminal** (`Models/ModelLibrary.swift`):
  - `ModelLibrary` — suggestion models (GGUF): catalogue of the three measured models with their Hugging Face links
    and exact sizes, download with progress / resume / cancel, checks (HTTP status, `GGUF` magic, exact size, free
    disk), download by link, import from a file, delete to the Trash. Checked with `TOLK_DL_TEST=<url>` against a local
    server (good file, wrong size, not a model, 404).
  - `ServerModels` — Ollama server: list (`/api/tags`), pull with progress (`/api/pull`), «Подготовить» builds
    `<base>-translate` = base + translator system prompt + temperature 0.3, num_ctx 8192, num_predict 8192
    (`/api/create`, the recipe of `gemma-translate`), delete (`/api/delete`). Create and delete were checked on the home server.
- **Statistics** (`TolkCore/UsageStats.swift`, `usage-stats.json`, numbers only, one year): translations per day,
  characters, median time and time to the first words, cache share, fallback share, errors, by origin / language pair
  / app / provider; and why a suggestion did not appear (`acMisses`: unsure, nothing, short, unread, moved, esc,
  type-translate, not-ready, secure, small-field) with advice. Recorded in `HistoryRecordingEngine` (independent of
  the history switch) and in `AutocompleteController.skip`. Existing history is counted in once.
- **Log**: local time instead of UTC; `Diagnostics.debug` for per-key detail (only with «Подробный журнал») — the
  `style: examples` line alone was 85 % of the log; rotation at 1 MB; one `translate:` line per translation (origin,
  pair, lengths, provider, route, ms, cache / fallback — never the text) and `translate: … FAILED`; `llama-server`
  runs with `-lv 2` unless the detailed log is on (its log grew by megabytes per hour); a viewer with filters and
  search in Настройки → Журнал.
- Self-test: 853 checks (`usageStats`).

## v0.8.1 — settings grouped into sections

- Every settings tab is split into named groups (`SSection`, a full-width heading): e.g. Автодополнение → «Подсказки»,
  «Что знает модель», «Помощники при наборе», «Ограничения». `MasonryLayout` lays each group out on its own and never
  uses more columns than the group has cards, so a short group fills the width.

## v0.8.2 — fine tuning of both models in settings

- **Translation model** (Перевод → «Параметры модели перевода»): `translateTemperature` (was a constant 0.1),
  `translateFixedSeed` (seed 42 or none), `translateCache`. Temperature and seed are part of the cache identity;
  without a fixed seed the cache is not read (a repeat is meant to give a new wording).
- **Suggestion model** (Автодополнение → «Тонкая настройка»): own confidence bars instead of the frequency preset
  (`autocompleteCustomConfidence`, `autocompleteFirstProb`, `autocompleteNextProb`; «Реже на батарее» still wins),
  the bar of the patient suggestion (`autocompletePatientProb`, was 0.08), `autocompleteTemperature` (top_k 40 when
  above zero, else greedy as before), `autocompleteContextSize` (`llama-server -c`, restarts the model),
  `autocompleteMinChars` (was 4). The hint of the first-word bar shows the expected share of right suggestions
  (`AutocompleteTuning.expectedAccuracy`, the measured curve).
- **Base instruction is visible**: the built-in rules of the suggestion model (`AutocompletePrompt.defaultRules`) are
  shown under the user's instructions, can be reworded (`autocompleteBaseRules`, empty = built-in) and reset; «Что
  получает модель целиком» shows the whole prompt for a sample message with the current settings.
- Defaults unchanged; endings set still 30 shown / 24 right. Self-test: 859 checks.

## v0.8.3 — one settings section on screen

- The sections of a settings tab are a second row under the tabs (`SettingsTab.sections`, underline style); only the
  selected one is shown (`SettingsModel.section`, remembered per tab in `settingsSections`). Links between tabs open
  the right section (`SettingsModel.open(_:section:)`). The status pills appear only when something is wrong; when
  all is fine a small «Всё работает» sits at the end of the tab row.

## v0.8.4 — settings sections on one page, divided by rules

- Replaces 0.8.3's one-section-at-a-time row (a misread of the user's choice): all sections of a tab are on one page
  again; each starts with a strong rule, a coloured icon and a large title (`SSection`, `SSections`). Titles, notes
  and icons live in `SettingsTab.sections`.

## v0.8.5 — log: what blocks an accepted suggestion, fewer false «problems»

- `not inserted, field check failed (rest-of-line)` now carries `tail=<n>:[…] app=…` — the shape of the text found
  after the caret (`AutocompleteSafety.tailShape`: letters «L», digits «9», other characters as code points; never
  the text). Seen in Claude desktop: a suggestion is shown (the tail was blank), Tab finds a non-blank tail with the
  same text before the caret. The cause is not known yet; the next occurrence will show what the tail is. Counted in
  the statistics as «not-inserted».
- Журнал → «Проблемы» no longer lists normal refusals (`step=text-selected`, `step=not-editable`).
- Dev runs (`TOLK_DL_TEST`, `TOLK_MAIN_DEMO`, `TOLK_RENDER_*`) write their log to a temporary folder, like the smoke run.

## v0.8.6 — Tab no longer falls through to the app

- Seen in the log: 10 of 35 accepted suggestions (Claude desktop, Slack) were dropped at the Tab press with
  `rest-of-line` — the re-read reported text after the caret although the text before it was unchanged — and Tab went
  to the app (the focus jumped). The end-of-line rule now applies only when a suggestion is shown; at insertion and at
  repositioning the app, the element and the text before the caret are still verified, and a non-blank tail is only
  logged (`inserting with text after the caret tail=…`). Why Electron reports that tail is still unknown; the log line
  will show its shape.

## v0.8.7 — a guide to the log

- `TolkCore/LogGuide.swift`: every kind of line in tolk.log (about a hundred) in 12 groups, each with a plain-words
  title, a meaning, a kind (обычное / к сведению / проблема) and, for problems, what to do. An entry matches by how
  the event starts plus optional substrings; the self-test checks that every sample is explained by its own entry.
- One source, three readers: Настройки → Журнал (click a line → explanation; «Что происходило» — problems and notes
  counted by kind; «Справочник» by group; the «Проблемы» filter and line colours come from the guide); a README
  written next to the log files at launch (`Diagnostics.writeGuide`); `docs/journal.md` (`tolk-cli --log-guide`).
- When a log line is added or reworded, add or update its `LogGuide` entry and regenerate `docs/journal.md`.

## v0.9.0 — open source

- MIT licence. The author's server nickname and LAN address are gone from the program: the server is «Сервер» in
  every message (`ServerText`), the default address is `http://127.0.0.1:11434`, the health line in the log is
  `server <model>: available / unavailable`. README, SETUP and the user guide describe the current version.

## v0.9.1 — instructions are editable in the app; official texts

- **`PromptCatalog`** (`TolkCore/PromptCatalog.swift`): every built-in instruction of the translator is a named block —
  base instruction, anti-calque lines (ru/uk, en, other), consistency rules, the three tones, the Ukrainian note,
  «Причесать», the editor's rules, phrase rules (`pattern => note` lines), and the example messages of the suggestion
  model. `Prompt`, `RefinePrompt`, `PhraseRules` and `AutocompletePrompt` read the blocks; the user's rewordings are
  `TolkConfig.prompts` (block id → text, missing = built-in). For ordinary texts the assembled prompts are
  byte-identical to 0.9.0 (compared old vs new on six requests).
- **Настройки → Перевод → «Инструкции модели»**: every block can be read, reworded and reset; «Проверка: весь запрос
  целиком» shows the full prompt for any sample text with the current settings. The suggestion model's examples are
  edited next to its base instruction (Автодополнение → «Что знает модель»).
- **Official and legal texts.** Found on the MIT licence: the model wrote «получившему копия», merged list items and
  used calques («в результате, из или в связи с»). The slip «копия» is not caused by any one line of the prompt —
  the model sits on a tie there and flips with almost any prompt change (minimal prompt: right; full prompt: wrong;
  removing any single line: still wrong). So two measures:
  - `translate.formal` — a block with the established legal formulas (ru/uk), added only when `FormalText.looksFormal`
    (two different markers such as «hereby», «without warranty», «liability», «настоящим», «договор»); 0 of 205 corpus
    messages trigger it.
  - the editor pass starts by itself for such texts of 200+ characters (`TolkConfig.autoEditor`: off / formal /
    always; popup and the translate page) and gets the same block. It fixes the agreement slip.
  Result on the licence, ru and uk: correct cases, «товарная пригодность / товарна придатність», «деликт / делікт»,
  three separate liability items, translated title. Not covered: the Documents page (chunks go straight to the engine).

## v0.9.2 — suggestion models: what is on disk, what was measured, what fits this Mac

- Models tab, local part: «Скачаны на этот Mac» lists only the files on disk (choose / delete) and names the Mac
  (`MacHardware`: chip, RAM). «Проверенные модели» is the reference list with the measurements per model (time of one
  suggestion, right endings, answered mid-sentence stops, RAM) and whether the RAM of this Mac is enough
  (`MacHardware.fit`: comfortable up to a quarter of RAM, tight up to a half). «Лучшая для этого Mac» is the
  best-ranked model that fits (`ModelLibrary.recommended`), no longer a fixed flag.
- «Другая модель» explains how to judge any other GGUF from those reference points (memory ≈ file size, time grows
  with size, bigger is not better, compare in the statistics) with the numbers of this Mac.
- A model that is not downloaded says «скачается N ГБ» instead of «N ГБ на диске».

## v0.9.3 — two small Qwen models measured

- Measured 2026-11-11 on endings-30 / midsentence-40 (shown, right) and a direct timing of warm 14-token suggestions:
  Gemma E2B 30 shown / 24 right, 39 of 40, ≈150 ms; Qwen 3.5 2B (unsloth Q4_K_M, 1.28 GB) 25 / 20, 30 of 40, ≈120 ms;
  Qwen 3.8 2B Distill (empero-ai Q4_K_M, 1.31 GB — a third-party fine-tune of Qwen 3.5 2B) 26 / 20, 29 of 40, ≈100 ms.
  Both small Qwens are faster and three times smaller, but answer less often and slip in Russian agreement
  («следующий кампания»). Gemma E2B stays the default. Their RAM (≈1.7 GB) is an estimate from the file size.
- Both are in the tested list. `ModelLibrary.recommended` now prefers the best model that fits with room to spare, so
  on an 8 GB Mac it is Qwen 3.5 2B, on 16 GB and more Gemma E2B.
- A GGUF built for another runtime does not load («unknown model architecture: 'qwen3_5'» from
  leventkoldas/Qwen3.8-2B-Distill-Q4_0-GGUF): take builds marked llama.cpp.

## v0.9.4 — official documents: editor and proofreader on the Documents page

- `DocumentTranslator` decides once per run whether the document is official (`AutoEditor.isOfficial` on the whole
  text) and, by the setting «Редактор после перевода», sends every paragraph of 80+ characters through
  `engine.refine` after its translation. `FormalContext.forced` (task-local) makes every paragraph of such a document
  get the official-text block, even one without markers of its own.
- `refine` for official texts ends with a proofreading pass (`refine.proofread`, editable in settings): the model sees
  only the translation and may fix nothing but grammar. Reason: with the formal tone the first pass wrote «прилагаться
  ко всех копиях» and the editor let it through; the narrow proofreader fixed both this and «получившему копия» and
  left correct sentences unchanged. `Proofread.accepts` rejects a result that changes length by more than 10 %, the
  number of lines or any digit.
- The MIT licence as a document, ru: all paragraphs correct, 75 s instead of 30 s (three passes on long paragraphs).
  Dev check: `TOLK_DOC_TEST=file.txt [TOLK_DOC_TO=ru] .build/debug/Tolk`.

## v0.9.5 — language lists start with Ukrainian, English, Russian, Polish

- `Language.main` = uk, en, ru, pl (also the first four enum cases, so every list built from `allCases` follows);
  `Language.others` = the rest by Russian name. The popup's «Перевести на» menu and the Documents target list use
  them. Default translation direction (`primaryLanguage` / `secondaryLanguage`) is unchanged.

## v0.9.6 — the bubble no longer covers the text being typed (Jira in Chrome)

- Jira's comment editor (an iframe with a contenteditable body) reports no caret and a field that hugs its text, so
  the fallback bubble «in the field's bottom-left corner» landed on the line being typed. The fallback is now just
  under the field. Typo-fix (instant) suggestions also look the caret up on a snapshot (`CaretLocator`) and move the
  bubble there, as model suggestions do. When the snapshot search fails the log says so
  (`caret not found on the snapshot (field WxH, lines read N, …)`), without any text.

## v0.9.7 — where suggestions work: per-place counters and an editor stand

- `UsageDay.acPlaces`: for every place the user types in — the app, and for a browser the site (`FocusedField.webHost`:
  host of the enclosing `AXWebArea`, looked up off the main thread) — how the caret was found (`exact` / `ocr` /
  `under`), accepted suggestions and failed insertions. `PlaceReport` turns the counters into a verdict (good, caret
  by snapshot, bubble under the field, insertion trouble). Shown in Настройки → Статистика → «Где подсказки
  работают». Only bundle ids, hosts and numbers are stored, locally.
- `scripts/stand/editors.html`: seven kinds of web input (textarea, input, plain contenteditable, paragraphs like
  ProseMirror, div lines like Gmail / Slack, a field that hugs its text like Jira comments, an iframe editor like
  TinyMCE) for a live pass. Not run yet: live passes are done when the user is away from the Mac.

## v0.9.8 — live pass over seven kinds of web editors (Chrome)

Run on `scripts/stand/editors.html` with the user away: type, wait for the suggestion, Tab (twice), a typo fix.

- **A wide «caret» rectangle is not a caret.** For a plain `contenteditable` Chrome answers the zero-length range
  with a strip as wide as the field and not on the caret's line (`raw=(64,689 900x21)`); it was taken as the caret,
  so the ghost text was drawn at the start of the line or over the text below the field. `caretRect` now treats a
  zero-length rectangle wider than `max(24, 2 × height)` like «no caret»: bubble + lookup on a snapshot.
- **The rest of a suggestion stays at the caret after Tab.** `scheduleReposition` looks the caret up on a snapshot
  again for such fields; the bubble is taken off the screen for that moment (its text read as part of the typed line).
- **Editors inside an iframe are read.** Their body may be one line high or have no frame of its own
  (`markers:no-rect`): `nearestRawFrame` takes the frame of the nearest parent. `CaretLocator` pads a field lower than
  48 pt by 10 pt above and below before reading it.
- Result: textarea, input, plain contenteditable, paragraphs (ProseMirror-like), div lines (Gmail-like), a field that
  hugs its text (Jira-like) and an iframe editor all show the suggestion at the caret (`ax=ocr`), insert the word on
  Tab and keep the rest at the caret; a typo fix appears at the caret and is applied.
- Not covered by the stand: the real Jira, Slack, Gmail and Google Docs (a canvas — not supported).

## v1.0.0

The user confirmed that suggestions work in Jira, Slack and Telegram, that every settings screen in use was clicked
through, and that Tab no longer falls through to the app. Closed for 1.0:

- **The rest of the built-in instructions are editable**: footnotes, variants of a sentence and of the whole
  translation, «Переписать» (shared part), «Составить» and «Что он имел в виду» are `PromptCatalog` blocks
  (`PromptCatalog+Tools.swift`, group `tools`). The blocks were generated from the original string literals;
  `tolk-cli --prompt-digest` gave identical fingerprints for all 124 assembled prompts before and after. Not moved:
  the per-button texts of «Переписать» and the second pass of «Составить» (`toneTransfer`).
- **Three interface flaws**: the status line under a translation shows the coloured dot alone when there is no room
  for the text (it used to be cut to «Gem…»; the text is in the tooltip); the Documents line says «переведено за …»
  after the translation instead of keeping the estimate; a suggestion bubble that does not fit to the right of the
  caret moves one line down and left instead of being cut.
- **README in English** (`README.md`), the Russian one is `README.ru.md`.
- A DMG is attached to the GitHub release.

## v1.0.8 — translation while typing is inserted in Teams

In Teams the translation appeared under the field but Tab answered «Поле не даёт выделить текст»: Teams (a web view) refuses `AXSelectedTextRange`, and without a checked selection Tolk does not paste. Now, when the accessibility selection is refused, Tolk presses ⌘A in the field (it is the focused one, checked just before), waits 0.15 s and reads what got selected: the same text (line breaks may differ) or a range over the whole text → paste; a part or more than the field → no paste, the old message; nothing reported → paste, there is nothing to check against (`TypeTranslate.keySelection`). The log now says why the first way was refused. Not checked live: the stand cannot be driven while the user is at the Mac; the user tries it in Teams.

## v1.0.7 — translation while typing: the messengers found on the Mac, each with a switch

The user's idea after 1.0.6: instead of a menu of running programs, let Tolk find the suitable ones itself. `TypeTranslateApps.known` is a list of messengers and mail programs (Telegram, Slack, Teams, WhatsApp, Discord, Messages, Signal, Viber, Messenger, Skype, Zoom, Mail, Outlook, Spark); the card shows those installed, each with a switch, plus the programs switched on some other way and «Другая программа» for the rest. The hint says plainly that only Telegram was checked.

## v1.0.6 — translation while typing: programs are added in settings

«Перевод при наборе» is switched on per program, and the only ways were the hotkey ⌃⌥R and the menu. On a Windows keyboard the hotkey did not reach Tolk (nothing in the log, registration was fine — most likely Alt and Win are swapped in the system), and the settings card only listed the programs with «Выключить везде». The card now has the list itself: every program with a remove button and «Добавить программу» (the running programs, as in «Тон по программам»). The hint under «Включать самому» says where the list is.

## v1.0.5 — a glossary per language pair; the glossary checked against the model

- **Sections per pair.** A rules file may hold several glossaries; the pair is read from the header: `## Глоссарий EN → UK`, `## Глоссарий EN → PL` (exactly two two-letter codes in capitals, `RulesStore.headerPair`). `RulesStore.lines` picks the lines for a translation: the section of exactly this pair, else the English–Russian one as before (the model finds the equivalent itself); sections without codes take part always. Two scripts are oriented by script with the old one-way rule; one script (English–Polish) by the header order. Polish terms are matched by stem (`polishStem`): «wydawca» finds «wydawców». The prompt wording for English ↔ Russian is unchanged (`--prompt-digest` identical); a pair with its own section gets «## Glossary: English → how to write it in Ukrainian». The source language is detected from the text when the caller does not pass it.
- **The fallback translator** takes terms for any pair that has its own section (before: Russian and English only). «Дневняя капа» — a bent word before a noun left as in the glossary — is put right (`fixAgreement`).
- **Audit of the user's glossary** (work profile, 81 pairs): a sentence with each term was generated and translated through the engine. One real miss («VAST wrappers» left in English), the other 16 flags were false (the generated sentence used the word in another sense, or the stem check missed a correct form). Fifty common adtech terms outside the glossary: the model is right on its own except «frequency cap» → «капа» and several inconsistent ones (supply, bid request, popunder, direct deal); eight pairs added on the user's choice. Garbage lines from earlier experiments removed, Ukrainian and Polish sections added as drafts.
- Not done: verb forms for the fallback translator («capped» is still left to the translator) — a Russian verb cannot be inflected by rule. The glossary page shows all sections as one list; a new term goes to the first section.

## v1.0.4 — Apple as the fallback measured; a greeting is no longer put in as a term

With the language packs downloaded Apple's translation works (0.12–0.46 s per phrase, nothing leaves the Mac). Eleven work phrases, Apple against Google:

- Plain: about equal. Apple kept «QPS» and wrote «расхождение» where Google wrote «количество кадров в секунду» and «несоответствие», but Apple slipped on ordinary speech («отпишемся» → «unsubscribe», «у себя» → «at home», «froud», «обилили трафик»).
- With the glossary switch: seven of eleven got better with Apple and none came out as nonsense (Google: five of nine better, two garbled). Small flaws remain («дневняя капа», «запределили трафик»). So the switch stays off by default, and its hint now gives both sets of numbers.
- Found on the way: the pair «Добрый день! → Hello,» was put in as a word and ate the «!». `FallbackGlossary.isPlainTerm` skips pairs with punctuation.
- `tolk-cli --provider apple` (the main run loop is turned while waiting — Apple's service does not answer to a blocked main thread).

## v1.0.3 — glossary for the fallback translator (a switch, off by default) and the state of Apple's languages

Away from home the server is not reachable and the text goes to Google as it is: «лимит» for «cap», «лента» for «feed», «количество кадров в секунду» for «QPS».

- `FallbackGlossary` puts glossary terms into the text before it is sent («lower the floor» → «lower the флор»); the translator builds the sentence around the word and usually inflects it. Only base forms and plain plurals are replaced (a verb form like «capped» is left alone), only into Russian and English. Every inserted term is looked for in the answer by its stem; the ones that did not survive are taken out and the text is sent again, then the plain translation is used — three requests at most. `RulesStore.glossaryPairs` picks the one rendering per term.
- Measured on nine work phrases through Google: five better, two unchanged, two with a garbled word NEXT to an inserted term («аккаунт был причинён из-за фрода»). A back-translation guard was tried and did not tell the bad ones from the good ones, so it was removed. Hence the switch «Глоссарий в запасном переводе» is OFF by default (`fallbackGlossary`) and its hint states these numbers. `tolk-cli --provider google` goes the same way (`TOLK_PLAIN_FALLBACK=1` = without terms).
- Also measured and rejected: the small suggestion model as the translator (wrong words: «под-публичеров») and as an editor of Google's answer (5 of 6 fine, one changed the meaning).
- Apple as the fallback «did not work» because no language pack was downloaded on the Mac. The settings now show the state of the pair (`AppleTranslationProvider.installed`) and a button that opens System Settings; before, the user learned it from a failed translation. Not checked by eye: the row appears only with Apple selected.

## v1.0.2 — the suggestion model no longer grows to 9 GB of memory

Found on the final check before leaving the app to run without development: `llama-server` with a 1.3 GB model had a 9.2 GB footprint after two hours. The cause is its prompt cache (`--cache-ram`), 8192 MiB by default: every distinct prompt left a 120–140 MiB entry until the limit was reached. `LocalModelServer` now starts it with `--cache-ram 512`: a few recent prompts are still kept (switching between two fields stays fast), the rest is dropped. The slot's own cache and `--cache-reuse` are unchanged, so typing in one field is as fast as before.

## v1.0.1 — Tolk does not touch an app until the user types in it

- Reported: in Slack a frame appeared around an element while nothing was being typed, and the first click on a
  button did not register. Cause: on every app activation Tolk asked the app for its accessibility tree
  (`AXManualAccessibility`) and, for Slack and Teams, also set `AXEnhancedUserInterface` — with that switch Chromium
  behaves as if a screen reader were running (focus frames, a first click that only moves the focus).
- Now nothing is set on activation. The switches are set at the first typed key in an app (not on ⌘/⌃ shortcuts,
  not in a password field or a switched-off app) — `ensureAccessibility`; a mouse click or an app switch takes
  `AXEnhancedUserInterface` back — `releaseAccessibility`. The first suggestion after a click may be missed while the
  app rebuilds its tree.
