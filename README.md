# Tolk

English · [Русский](README.ru.md)

Tolk is a local translator and system-wide autocomplete for macOS. Translation is done by your own language model (Ollama on this Mac or on a machine in your home network). Typing suggestions come from a small model that runs on the Mac itself. Text can leave your computer only through the fallback translator (Google), which you can replace with the built-in macOS translation or switch off.

Version 1.0.0. The interface is in Russian. This is a personal project built around one person's habits, but the code is open (MIT): take it, build it, change it.

## What it does

**Translation**
- A popup next to the cursor on double ⌘C; the translation streams in as it is generated.
- Footnotes for debatable terms, back-translation, alternatives for a word and for the whole text, a check for lost numbers and links, an editor pass against word-for-word renderings.
- Tone per application (chat or letter), 24 languages, automatic direction.
- Glossary and profiles (for example "Work" and "Home"), each with its own rules and terms.
- Official and legal texts get the established legal formulas plus an automatic editor and proofreader pass.

**Conversations**
- "Reply": write in your language, the reply is translated into the other person's language with their message as context. One-click ready replies.
- "Translate while typing": type in your language, the translation appears under the field, Tab inserts it.
- The big window: Translate, Reply and Compose modes, hints, variants, rewriting (shorter, softer, firmer, simpler, businesslike, direct, formal / informal address).

**Everything else**
- Quick actions in any app: translate and replace the selection (⌃⌥T), polish text (⌃⌥P), fix the keyboard layout (⌃⌥L).
- Photos and screenshots: on-device text recognition and translation (⌥⇧S for a screen area).
- Documents: PDF, Word, RTF, ODT, HTML, TXT, MD; export to DOCX, RTF, TXT, MD.
- Translation history with search, kept only on this Mac.
- Autocomplete: grey text at the caret in any app (Tab accepts a word, → the whole suggestion), typo fixes, emoji.

**Settings without touching code**
- A settings page made of cards; every switch explains what happens in each position.
- Models are downloaded, chosen and deleted from the interface, both for suggestions (on the Mac) and for translation (on the Ollama server). Tested models are listed with their measurements and whether this Mac has enough memory.
- Fine tuning: temperature, confidence thresholds, context size. Every built-in instruction the models get can be read, reworded and reset.
- Statistics (how much was translated and from where, how many suggestions were accepted, why a suggestion did not appear, how suggestions behave in each app and site) and a log viewer that explains every line.

## Requirements

- A Mac with macOS 14 or later, Apple Silicon. Building needs the Command Line Tools with Swift 6.2 (`xcode-select --install`); Xcode is not required.
- A translation model server: Ollama on any computer (Mac, Windows, Linux) with Gemma 4 26B, about 24 GB of memory in total. See [SETUP.md](SETUP.md) (in Russian).
- For autocomplete: Homebrew `llama.cpp` and a model file (1.3–3.4 GB; downloaded from the settings).
- There is no Windows or Linux client. Cloud model APIs are not supported.

## Install

Download `Tolk-1.0.0.dmg` from the [Releases](../../releases) page, open it and drag Tolk to Applications. The build is signed with a local certificate, not notarized by Apple: on first launch right-click the app and choose Open.

Or build from source:

```bash
scripts/build-app.sh
```

```bash
scripts/install.sh
```

## Documents

- [SETUP.md](SETUP.md) — installation and first setup (Russian).
- [docs/USER-GUIDE.md](docs/USER-GUIDE.md) — every feature and shortcut (Russian).
- [docs/journal.md](docs/journal.md) — what the log lines mean and what to do about them (Russian).
- [ARCHITECTURE.md](ARCHITECTURE.md) — how it is built, the measurements and the version log (English).

## Privacy

Translation goes through your own model. If the model server is unreachable, Google translates by default; in Settings this can be changed to the on-device macOS translation or to "send nothing". Suggestions are computed on the Mac. History, style memory, statistics and the log stay on your disk; the log and the statistics contain no text, only numbers and application names.

## License

[MIT](LICENSE). The models (Gemma, Qwen and others) are distributed under their own terms and are not part of this repository.
