#!/bin/zsh
# One-time setup on an Apple Silicon Mac: dependencies, models, build, launch.
# Usage: ./scripts/setup.sh            (Parakeet v3, official ggml-org weights)
#        MURMUR_MODEL=v2 ./scripts/setup.sh   (Parakeet v2, English-only, community conversion)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $(uname -m) == arm64 ]] || { echo "Murmur needs an Apple Silicon Mac."; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Run: xcode-select --install"; exit 1; }

echo "==> Dependencies (whisper.cpp provides libparakeet + Silero VAD; Ollama runs the local LLM)"
brew list whisper.cpp >/dev/null 2>&1 || { brew update >/dev/null; brew install whisper.cpp; }
command -v ollama >/dev/null || brew install ollama
[[ -f /opt/homebrew/include/parakeet.h ]] || { echo "Your whisper-cpp has no Parakeet support; run: brew upgrade whisper-cpp"; exit 1; }

M="$HOME/Library/Application Support/Murmur/models"
mkdir -p "$M"
fetch() { [[ -s "$M/$2" ]] || { echo "==> Downloading $2"; curl -L --fail --progress-bar -o "$M/$2.part" "$1" && mv "$M/$2.part" "$M/$2"; }; }
if [[ ${MURMUR_MODEL:-v3} == v2 ]]; then
  fetch https://huggingface.co/JoaoZaokk/parakeet-tdt-0.6b-v2-ggml/resolve/main/ggml-parakeet-tdt-0.6b-v2-q8_0.bin ggml-parakeet-tdt-0.6b-v2-q8_0.bin
else
  fetch https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin ggml-parakeet-tdt-0.6b-v3-q8_0.bin
fi
fetch https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin ggml-silero-v6.2.0.bin

echo "==> Local LLM for cleanup / Ask AI"
pgrep -x ollama >/dev/null || (brew services start ollama >/dev/null 2>&1 || (ollama serve >/dev/null 2>&1 &))
for i in {1..40}; do curl -s localhost:11434/api/tags >/dev/null && break; sleep 0.5; done
curl -s localhost:11434/api/tags >/dev/null || { echo "Ollama isn't running. Start the Ollama app, then rerun this script."; exit 1; }
ollama pull qwen3:4b-instruct

echo "==> Building"
./scripts/build.sh
open "$( [[ -d /Applications/Murmur.app ]] && echo /Applications || echo ~/Applications )/Murmur.app"
echo "Done. Grant Microphone + Accessibility when asked. Dictate with ⌃⌥Space."
