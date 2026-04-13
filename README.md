# whisper-term

Terminal-based real-time audio transcription for macOS. Captures audio from any app or the microphone and transcribes it offline using NVIDIA's [Parakeet](https://huggingface.co/collections/nvidia/parakeet) speech recognition models running on Apple Silicon GPU.

## Features

- **Per-app audio capture** using macOS Core Audio taps (macOS 14.4+)
- **Microphone capture** for live transcription
- **Parakeet v3 600M** — best-in-class ASR model via [parakeet.cpp](https://github.com/Frikallo/parakeet.cpp) with Metal GPU acceleration
- **Persistent inference server** — model loads once, transcribes chunks without reload overhead
- **Streaming EOU mode** — real-time output with the 120M end-of-utterance model
- **Whisper fallback** — optional whisper.cpp backend
- **Pipe-friendly** — `--quiet` and `--output` flags for scripting and downstream analysis

## Requirements

- macOS 14.4+ (for Core Audio taps)
- Apple Silicon Mac (for Metal GPU)
- Xcode (for Metal shader compiler)
- Python 3.10+
- [huggingface-cli](https://huggingface.co/docs/huggingface_hub/guides/cli) (for model download)

## Quick Start

```bash
git clone --recursive git@github.com:guanyilun/whisper-term.git
cd whisper-term
./scripts/setup.sh   # clones parakeet.cpp, downloads model, builds everything
```

Or step by step:

```bash
make build            # build audiocapture + install Python package
make build-parakeet   # build parakeet.cpp with Metal GPU
make install          # install binaries to ~/.local/bin
```

## Usage

### Microphone transcription

```bash
whisper-term --mic --engine parakeet
```

### App audio capture

```bash
# List running apps
audiocapture --list

# Transcribe Firefox audio
audiocapture --app org.mozilla.firefox | whisper-term --engine parakeet
```

### Options

```
--engine {parakeet,streaming,whisper}   Transcription engine (default: streaming)
--mic                                    Capture from microphone
--chunk SECONDS                          Chunk duration for offline engines (default: 5.0)
--quiet, -q                              Suppress non-transcript output
--output FILE, -o FILE                   Write transcript to file (append mode)
--model PATH                             Path to model file
--vocab PATH                             Path to vocab file
```

### Engines

| Engine | Model | Speed | Quality | Output |
|--------|-------|-------|---------|--------|
| `parakeet` | Parakeet v3 600M | ~300ms/5s chunk | Best | Per-chunk |
| `streaming` | Parakeet EOU 120M | Real-time | Good | Word-by-word |
| `whisper` | Whisper base.en | ~500ms/5s chunk | Good | Per-chunk |

### Scripting

```bash
# Clean transcript to file
audiocapture --app us.zoom.xos | whisper-term --engine parakeet -q -o meeting.txt

# Tail the transcript
tail -f meeting.txt
```

## Architecture

```
audiocapture (Swift)          whisper-term (Python)           parakeet-server (C++)
┌──────────────────┐         ┌──────────────────────┐        ┌─────────────────────┐
│ Core Audio Taps  │  PCM    │ Chunk + normalize    │  WAV   │ Parakeet v3 600M    │
│ PID → tap →      │───────→│ Write temp WAV       │──────→│ Metal GPU inference  │
│ aggregate device │ stdout  │ Send path to server  │ stdin  │ TDT decoder         │
│ 48kHz→16kHz      │         │ Read transcription   │        │ SentencePiece decode │
└──────────────────┘         └──────────────────────┘        └─────────────────────┘
```

## Project Structure

```
whisper-term/
├── src/whisper_term/       # Python CLI and transcription logic
│   ├── cli.py              # Main entry point
│   └── formatter.py        # Output formatting
├── audiocapture/           # Swift per-app audio capture (Core Audio taps)
│   └── Sources/audiocapture/
│       ├── AudioCapture.swift
│       └── main.swift
├── parakeet-server/        # Custom C++ persistent inference server
│   └── main.cpp
├── scripts/
│   └── setup.sh            # One-command setup
├── Makefile
└── pyproject.toml
```

## License

MIT
