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
- Measured (autocomplete-eval.md, rounds 2–3): Gemma 26B on vkbox via Ollama ≈1.35 s and over-confident — kept for
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
- Measured on vkbox (2026-11-10): num_ctx 8192 vs 32768 — generation ≈26 vs ≈22 tok/s, first token the same (~1.1 s).
  Ollama reloads the model (~30 s) whenever a request asks for another num_ctx, so change it only in the Modelfile.

### v0.6.5 — «Перевод при наборе» (type in your language, insert the translation)
- ⌃⌥R toggles the mode per app (`TolkConfig.typeTranslateApps`, optional `typeTranslateAuto` when the partner's last
  message on screen is in another language; off by default). Also in the menu bar and Settings → Автодополнение.
- After a 500 ms pause the whole field text is translated into the partner's language (`TolkCore/TypeTranslate.swift`:
  partner message + language from `ScreenContext`, else `secondaryLanguage`) with `replyTo`, app tone and thread
  context; the engine for this mode has no fallback (vkbox down → silence, nothing goes to Google).
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
- vkbox: `gemma-translate` recreated with num_ctx 8192 (old one kept as `gemma-translate-32k`). Self-test: 690 checks.

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

