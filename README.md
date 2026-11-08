<p align="center"><img src="docs/icon.png" width="96" alt="Murmur icon"></p>

<h1 align="center">Murmur</h1>

**TL;DR: Wispr-Flow-style voice dictation for macOS that runs 100% on your Mac. Tap a key, talk, and clean text appears at your cursor about a second after you stop. Speech-to-text is NVIDIA Parakeet (via whisper.cpp, on the GPU) and cleanup uses a local model through Ollama. "Ask AI" answers by voice with rich cards, and can read live data from your own self-hosted services (finance dashboard, Immich, Seerr, Beszel) over your private network. A third mode turns what you say into a Claude Code session. No account, no telemetry; private data stays on the local model.**

## What it does

| Mode | Shortcut | What happens |
|---|---|---|
| **Dictate** | `⌥Space` or `⌃⌥Space` (or macro pad key 1 = F18) | Transcribes, removes "um/uh", applies "actually no, make it 4" corrections, pastes into the focused app |
| **Ask AI** | `⌥/` or `⌃⌥/` (or pad key 2 = F19) | Speak a question; a floating panel streams the answer with cards (weather, money, photos, media, server). Press again for a follow-up. Copy or Insert |
| **Claude Code** | `⌃⌥Return` (or pad keys 1+2 together) | Opens a [cmux](https://cmux.dev) (optional) workspace running `claude "<what you said>"`. If you're looking at a Claude session in cmux, it sends the instruction there instead |

- **Tap** to start, and it **stops automatically when you stop talking** (Silero VAD, adjustable pause). Or **hold** for push-to-talk. `Esc` cancels.
- Your clipboard is restored after pasting, and dictations are marked transient so clipboard managers skip them.
- Menu bar dropdown, searchable history, and per-app context for cleanup.
- Agent mode will only ever type into a pane whose foreground process is `claude`, never into a plain shell.

Measured on an M1 Pro: ~0.2 s to transcribe 12 s of speech, ~1 s for cleanup with `qwen3:4b-instruct`.

## Install (Apple Silicon, macOS 14+)

```sh
git clone https://github.com/1300Sarthak/murmur.git && cd murmur
./scripts/setup.sh
```

`setup.sh` installs `whisper-cpp` and `ollama` with Homebrew, downloads the models (~1.3 GB total) into `~/Library/Application Support/Murmur/models`, pulls `qwen3:4b-instruct`, builds, and launches. It needs no admin rights: it installs to `~/Applications` if `/Applications` isn't writable, and signs ad-hoc if you have no developer certificate.

On first launch, allow **Microphone** and **Accessibility** (Accessibility is what lets it paste). Without Accessibility it copies to the clipboard instead.

Requirements: Apple Silicon, macOS 14+, Homebrew, Xcode or Command Line Tools with Swift 5.9+.

Without an Apple Development certificate the app is signed ad-hoc, so macOS may ask for the permissions again after each rebuild.

### Models

| Model | WER on 73 LibriSpeech clips | Notes |
|---|---|---|
| Parakeet TDT 0.6B **v2** | **2.78%** | English-only, most accurate. `MURMUR_MODEL=v2 ./scripts/setup.sh` (community ggml conversion) |
| Parakeet TDT 0.6B v3 | 3.65% | Default, official [ggml-org](https://huggingface.co/ggml-org/parakeet-GGUF) weights, 25 languages |

Switch models in Settings. Any `ggml-parakeet-*.bin` you drop into the models folder shows up there.

## Macro pad (optional)

Cheap 3-key + knob pads (USB `1189:8890`) can be remapped with [ch57x-keyboard-tool](https://github.com/kriomant/ch57x-keyboard-tool):

```sh
cargo install ch57x-keyboard-tool
ch57x-keyboard-tool upload < macropad/murmur-pad.yaml   # F18, F19, play/pause, knob = volume
```

These pads send press and release together, so the keys act as toggles. Auto-stop ends the recording.

## Ask AI

**Providers.** Auto uses the Claude Code or Codex CLI (your own subscription) when online and falls back to the local Ollama model offline. Pick one in Settings. Weather questions get a live forecast card from Open-Meteo.

**Your own services (optional).** Point Murmur at a server you run, typically over Tailscale, and ask about it by voice. Each answer comes with a card; follow-ups are answered only from data already shown, never guessed.

| Ask | Source | Example |
|---|---|---|
| Money | a [`fin`-style](#finance-endpoint) finance dashboard | "how much NVIDIA do I have", "what did I spend last month", "show me the uncategorized" |
| Photos | [Immich](https://immich.app) | "how many photos of Alex do I have", "pull up what I did on October 7th" (opens Immich filtered to that day) |
| Movies & shows | [Seerr](https://github.com/seerr-team/seerr) / Overseerr / Jellyseerr | "request Dune on Seerr" (shows the match; nothing is requested until you click, using your default quality profile) |
| Server | [Beszel](https://beszel.dev) | "how much space is left on my 8TB drive", "what's using the most CPU on my server" |

Set it up in **Settings → Homelab** (host name) and **Settings → Finance** (dashboard URL). API keys go in the same screen and are stored in the macOS Keychain (service `murmur.homelab`), never in preferences or the repo. Money, photo, media and server answers use the local model only, unless you turn on "Allow cloud models".

<a id="finance-endpoint"></a>The finance card expects `GET <dashboard>/api/fin/<command>` to return the JSON of a read-only finance CLI (`holdings`, `accounts`, `overview`, `spending`, `txns`, `brief`).

## Claude Code mode

Needs [cmux](https://cmux.dev) and the `claude` CLI. In Settings you can set:

- **Start in folder**: the working directory for new sessions
- **Extra claude flags**: for example `--permission-mode auto`
- **cca account** (optional): to launch through a `cca <account>` multi-account wrapper instead of plain `claude`

The prompt is passed through a file, so spoken text is never parsed by your shell.

## Privacy

Dictation and cleanup run locally (Ollama on `127.0.0.1`). Ask AI calls the Claude/Codex CLI only when you choose a frontier provider, and never for money, photo, media or server questions unless you allow it. Homelab skills talk only to the host you configure. Finance, photo, media and server answers are never written to history. History is stored in `~/Library/Application Support/Murmur/history.json`; clear it from the History window.

## Development

```sh
./scripts/build.sh                          # build + install
Murmur.app/Contents/MacOS/Murmur --demo     # cycle UI states with fake data (no mic, no paste)
Murmur.app/Contents/MacOS/Murmur --selftest clip.wav   # transcribe + clean up a file, print timings
Murmur.app/Contents/MacOS/Murmur --vadtest clip.wav    # show where auto-stop would trigger
swift build && .build/debug/Murmur --fintest <fixtures>  # debug builds only: finance intents/answers from saved JSON (also --phototest, --mediatest, --hosttest); exits 1 on any failure
python3 scripts/eval-cleanup.py Resources/cleanup-prompt.txt   # evaluate the cleanup prompt
```

Code map: `Engines.swift` (Parakeet, Silero VAD, audio capture, Ollama), `AppModel.swift` (state machine), `Agent.swift` (cmux / Claude Code), `Providers.swift` (Claude/Codex/Ollama), `Rich.swift` (answer cards), `Weather.swift`, `Finance.swift`, `Skills.swift` (homelab skills + Keychain) with `Photos.swift`, `Media.swift`, `Host.swift`, `System.swift` (hotkeys, paste, prefs, history), `Views.swift` and `Panels.swift` (UI).

## License

MIT
