import argparse
import io
import os
import signal
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 4  # float32

import re

def filter_english(text: str) -> str:
    """Remove non-ASCII characters (filters out Russian/CJK hallucinations from multilingual models)."""
    # Keep only ASCII printable chars and common punctuation
    filtered = re.sub(r'[^\x20-\x7E]', '', text)
    # Clean up leftover artifacts (multiple spaces, leading commas, etc.)
    filtered = re.sub(r'\s+', ' ', filtered).strip()
    filtered = re.sub(r'^[,.\s]+', '', filtered)
    return filtered


def write_wav(pcm_f32: np.ndarray, path: str, sample_rate: int = 16000) -> None:
    """Write float32 PCM as a 16-bit WAV file (what whisper-cli expects)."""
    pcm_i16 = (pcm_f32 * 32767).clip(-32768, 32767).astype(np.int16)
    with open(path, "wb") as f:
        num_samples = len(pcm_i16)
        data_size = num_samples * 2  # 16-bit = 2 bytes per sample
        # WAV header
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        f.write(pcm_i16.tobytes())


def run_whisper_cli(wav_path: str, model_path: str, language: str, timestamps: bool) -> str:
    """Run whisper-cli on a WAV file and return the transcription text."""
    cmd = [
        "whisper-cli",
        "-m", model_path,
        "-l", language,
        "-f", wav_path,
        "--no-prints",
        "-t", "4",
        "--flash-attn",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        text = result.stdout.strip()
        return text
    except subprocess.TimeoutExpired:
        return ""
    except FileNotFoundError:
        print("Error: whisper-cli not found. Install with: brew install whisper-cpp", file=sys.stderr)
        sys.exit(1)


def run_parakeet_cli(wav_path: str, model_path: str, vocab_path: str, timestamps: bool) -> str:
    """Run parakeet CLI on a WAV file and return the transcription text."""
    # Auto-detect model type from filename
    if "v3" in model_path:
        model_type = "tdt-600m"
    elif "600m" in model_path:
        model_type = "tdt-600m-v2"
    else:
        model_type = "tdt-ctc-110m"
    cmd = [
        "parakeet",
        model_path,
        wav_path,
        "--vocab", vocab_path,
        "--gpu",
        "--model", model_type,
    ]
    if timestamps:
        cmd.append("--timestamps")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        text = result.stdout.strip()
        # Only return text after the "--- Transcription (...) ---" line
        lines = text.split("\n")
        output_lines = []
        found_header = False
        for line in lines:
            if line.startswith("---") and "Transcription" in line:
                found_header = True
                continue
            if found_header and line.strip():
                output_lines.append(line.strip())
        return " ".join(output_lines)
    except subprocess.TimeoutExpired:
        return ""
    except FileNotFoundError:
        print("Error: parakeet not found. Build with: cd parakeet.cpp && make build", file=sys.stderr)
        sys.exit(1)


def find_parakeet_server() -> str:
    """Find parakeet-server binary."""
    candidates = [
        "parakeet.cpp/build/examples/server/parakeet-server",
        os.path.expanduser("~/.local/bin/parakeet-server"),
        "/usr/local/bin/parakeet-server",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return "parakeet-server"


def run_streaming_mode(model_path: str, vocab_path: str) -> None:
    """Stream PCM from stdin through parakeet-server (EOU model, no chunking needed)."""
    server_bin = find_parakeet_server()
    cmd = [server_bin, model_path, vocab_path, "--gpu", "--model", "eou-120m"]

    print(f"Starting parakeet-server (streaming EOU)...", file=sys.stderr)
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
        env={**os.environ, "PYTHONUNBUFFERED": "1"},
    )

    import threading

    def pump_stderr():
        for line in proc.stderr:
            try:
                sys.stderr.buffer.write(line)
                sys.stderr.buffer.flush()
            except (AttributeError, OSError):
                pass

    threading.Thread(target=pump_stderr, daemon=True).start()

    # Forward stdin PCM directly to parakeet-server
    def forward_stdin():
        try:
            while True:
                data = sys.stdin.buffer.read(4096)
                if not data:
                    break
                proc.stdin.write(data)
                proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    threading.Thread(target=forward_stdin, daemon=True).start()

    # Read transcription output byte-by-byte to avoid buffering
    try:
        buf = b""
        while True:
            b = proc.stdout.read(1)
            if not b:
                break
            if b == b"\n":
                text = buf.decode("utf-8", errors="replace")
                buf = b""
                if text:
                    text = text.replace("<EOU>", "").strip()
                    if text:
                        print(text, flush=True)
            else:
                buf += b
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        proc.wait()

    print("\nDone.", file=sys.stderr)


def run_stdin_persistent(model_path: str, vocab_path: str, model_type: str, chunk_seconds: float) -> None:
    """Read PCM from stdin, buffer into chunks, transcribe with persistent parakeet-server."""
    import threading

    chunk_bytes = int(chunk_seconds * SAMPLE_RATE * BYTES_PER_SAMPLE)

    server_bin = find_parakeet_server()
    cmd = [server_bin, model_path, vocab_path, "--gpu", "--model", model_type]

    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, bufsize=0,
    )

    # Wait for server to be ready
    while True:
        line = proc.stderr.readline().decode()
        if not line:
            break
        try:
            print(line.strip(), file=sys.stderr)
        except (AttributeError, OSError):
            pass
        if "ready" in line.lower():
            break

    def pump_stderr():
        for line in proc.stderr:
            pass
    threading.Thread(target=pump_stderr, daemon=True).start()

    buf = b""
    stop = False

    def handle_sigint(sig, frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGINT, handle_sigint)

    try:
        while not stop:
            data = sys.stdin.buffer.read(chunk_bytes - len(buf))
            if not data:
                break
            buf += data

            if len(buf) >= chunk_bytes:
                pcm = np.frombuffer(buf, dtype=np.float32)
                buf = b""

                rms = np.sqrt(np.mean(pcm ** 2))
                if rms < 0.003:
                    continue

                # Only normalize quiet audio (e.g. mic input)
                # App audio is usually already at good levels
                peak = np.max(np.abs(pcm))
                if peak > 0 and peak < 0.1:
                    pcm = pcm / peak * 0.9

                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    write_wav(pcm, tmp.name, SAMPLE_RATE)
                    tmp_path = tmp.name

                proc.stdin.write((tmp_path + "\n").encode())
                proc.stdin.flush()

                text_lines = []
                while True:
                    line = proc.stdout.readline().decode("utf-8", errors="replace").rstrip("\n")
                    if line == "---END---":
                        break
                    if line:
                        text_lines.append(line)

                os.unlink(tmp_path)

                text = filter_english(" ".join(text_lines))
                if text:
                    print(text, flush=True)

    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        proc.wait()


def run_stdin_mode(model_path: str, language: str, timestamps: bool, chunk_seconds: float,
                   engine: str = "whisper", vocab_path: str = "") -> None:
    """Read PCM from stdin, buffer into chunks, transcribe."""
    chunk_bytes = int(chunk_seconds * SAMPLE_RATE * BYTES_PER_SAMPLE)
    print(f"Buffering {chunk_seconds}s chunks, transcribing with {engine}...", file=sys.stderr)

    buf = b""
    global_time = 0.0
    stop = False

    def handle_sigint(sig, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_sigint)

    try:
        while not stop:
            data = sys.stdin.buffer.read(chunk_bytes - len(buf))
            if not data:
                break
            buf += data

            if len(buf) >= chunk_bytes:
                pcm = np.frombuffer(buf, dtype=np.float32)
                buf = b""

                # Skip near-silence chunks
                rms = np.sqrt(np.mean(pcm ** 2))
                if rms < 0.005:
                    global_time += chunk_seconds
                    continue

                with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
                    write_wav(pcm, tmp.name, SAMPLE_RATE)
                    if engine == "parakeet":
                        text = run_parakeet_cli(tmp.name, model_path, vocab_path, timestamps)
                    else:
                        text = run_whisper_cli(tmp.name, model_path, language, timestamps)

                if text:
                    if timestamps:
                        print(text, flush=True)
                    else:
                        # Strip whisper-cli timestamp prefixes if present
                        lines = []
                        for line in text.split("\n"):
                            line = line.strip()
                            if line.startswith("["):
                                bracket_end = line.find("]")
                                if bracket_end != -1:
                                    line = line[bracket_end + 1:].strip()
                            if line:
                                lines.append(line)
                        if lines:
                            print(" ".join(lines), flush=True)

                global_time += chunk_seconds

    except KeyboardInterrupt:
        pass

    # Flush remaining buffer
    if buf and len(buf) >= BYTES_PER_SAMPLE:
        remainder = len(buf) % BYTES_PER_SAMPLE
        if remainder:
            buf = buf[:len(buf) - remainder]
        pcm = np.frombuffer(buf, dtype=np.float32)
        rms = np.sqrt(np.mean(pcm ** 2))
        if rms >= 0.005:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
                write_wav(pcm, tmp.name, SAMPLE_RATE)
                text = run_whisper_cli(tmp.name, model_path, language, timestamps)
            if text:
                print(text, flush=True)

    print("\nDone.", file=sys.stderr)


def run_mic_streaming(model_path: str, vocab_path: str) -> None:
    """Stream microphone audio through parakeet-server (EOU model)."""
    import sounddevice as sd
    import threading

    server_bin = find_parakeet_server()
    cmd = [server_bin, model_path, vocab_path, "--gpu", "--model", "eou-120m"]

    print(f"Starting parakeet-server (streaming EOU)...", file=sys.stderr)
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, bufsize=0,
    )

    def pump_stderr():
        for line in proc.stderr:
            try:
                sys.stderr.buffer.write(line)
                sys.stderr.buffer.flush()
            except (AttributeError, OSError):
                pass

    threading.Thread(target=pump_stderr, daemon=True).start()

    print("Listening on microphone (streaming)... Speak now.", file=sys.stderr)

    stop = False
    # Use a fixed gain based on typical mic levels (~15x boost)
    # This avoids per-block normalization artifacts
    gain = [15.0]  # mutable for callback access

    def mic_callback(indata, frames, time_info, status):
        if stop:
            return
        try:
            pcm = indata[:, 0] * gain[0]
            np.clip(pcm, -1.0, 1.0, out=pcm)
            proc.stdin.write(pcm.astype(np.float32).tobytes())
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE, channels=1, dtype="float32",
        blocksize=int(SAMPLE_RATE * 0.1),  # 100ms blocks
        callback=mic_callback,
    )

    try:
        with stream:
            buf = b""
            while True:
                b = proc.stdout.read(1)
                if not b:
                    break
                if b == b"\n":
                    text = buf.decode("utf-8", errors="replace")
                    buf = b""
                    if text:
                        is_eou = "<EOU>" in text
                        text = text.replace("<EOU>", "").strip()
                        if text:
                            if is_eou:
                                print(text, flush=True)  # newline after end-of-utterance
                            else:
                                print(text, end="", flush=True)  # continue on same line
                else:
                    buf += b
    except KeyboardInterrupt:
        pass
    finally:
        stop = True
        proc.terminate()
        proc.wait()

    print("\nDone.", file=sys.stderr)


def run_mic_persistent(model_path: str, vocab_path: str, model_type: str, chunk_seconds: float) -> None:
    """Capture from microphone, transcribe with persistent parakeet-server (no model reload)."""
    import sounddevice as sd
    import threading

    server_bin = find_parakeet_server()
    cmd = [server_bin, model_path, vocab_path, "--gpu", "--model", model_type]

    print(f"Starting parakeet-server ({model_type}, persistent)...", file=sys.stderr)
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, bufsize=0,
    )

    # Wait for server to be ready
    while True:
        line = proc.stderr.readline().decode()
        if not line:
            break
        try:
            print(line.strip(), file=sys.stderr)
        except (AttributeError, OSError):
            pass
        if "ready" in line.lower():
            break

    def pump_stderr():
        for line in proc.stderr:
            pass

    threading.Thread(target=pump_stderr, daemon=True).start()

    chunk_samples = int(chunk_seconds * SAMPLE_RATE)
    print(f"Listening on microphone ({chunk_seconds}s chunks)... Speak now.", file=sys.stderr)

    stop = False
    def handle_sigint(sig, frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGINT, handle_sigint)

    try:
        while not stop:
            audio = sd.rec(chunk_samples, samplerate=SAMPLE_RATE, channels=1, dtype="float32", blocking=True)
            pcm = audio[:, 0]

            rms = np.sqrt(np.mean(pcm ** 2))
            if rms < 0.005:
                continue

            # Normalize
            peak = np.max(np.abs(pcm))
            if peak > 0:
                pcm = pcm / peak * 0.9

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                write_wav(pcm, tmp.name, SAMPLE_RATE)
                tmp_path = tmp.name

            # Send WAV path to persistent server
            proc.stdin.write((tmp_path + "\n").encode())
            proc.stdin.flush()

            # Read response until ---END---
            text_lines = []
            while True:
                line = proc.stdout.readline().decode("utf-8", errors="replace").rstrip("\n")
                if line == "---END---":
                    break
                if line:
                    text_lines.append(line)

            import os
            os.unlink(tmp_path)

            text = filter_english(" ".join(text_lines))
            if text:
                print(text, flush=True)

    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        proc.wait()

    print("\nDone.", file=sys.stderr)


def run_mic_mode(model_path: str, language: str, timestamps: bool, chunk_seconds: float,
                 engine: str = "whisper", vocab_path: str = "") -> None:
    """Capture from microphone, transcribe with whisper-cli."""
    import sounddevice as sd

    chunk_samples = int(chunk_seconds * SAMPLE_RATE)
    print(f"Listening on microphone ({chunk_seconds}s chunks)... Speak now.", file=sys.stderr)

    stop = False

    def handle_sigint(sig, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_sigint)

    try:
        while not stop:
            audio = sd.rec(chunk_samples, samplerate=SAMPLE_RATE, channels=1, dtype="float32", blocking=True)
            pcm = audio[:, 0]

            rms = np.sqrt(np.mean(pcm ** 2))
            if rms < 0.005:
                continue

            peak = np.max(np.abs(pcm))
            if peak > 0:
                pcm = pcm / peak * 0.9

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
                write_wav(pcm, tmp.name, SAMPLE_RATE)
                text = run_whisper_cli(tmp.name, model_path, language, timestamps)

            if text:
                lines = []
                for line in text.split("\n"):
                    line = line.strip()
                    if line.startswith("["):
                        bracket_end = line.find("]")
                        if bracket_end != -1:
                            line = line[bracket_end + 1:].strip()
                    if line:
                        lines.append(line)
                if lines:
                    print(" ".join(lines), flush=True)

    except KeyboardInterrupt:
        pass

    print("\nDone.", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="whisper-term",
        description="Real-time audio transcription using whisper.cpp",
    )
    parser.add_argument(
        "--model", "-m",
        default=None,
        help="Path to GGML model file (default: auto-detect from homebrew)",
    )
    parser.add_argument(
        "--language", "-l",
        default="en",
        help="Language code (default: en)",
    )
    parser.add_argument(
        "--timestamps", "-t",
        action="store_true",
        help="Show timestamps for each segment",
    )
    parser.add_argument(
        "--mic",
        action="store_true",
        help="Capture audio from the microphone instead of stdin",
    )
    parser.add_argument(
        "--chunk", "-c",
        type=float,
        default=5.0,
        help="Chunk duration in seconds (default: 5.0). Larger = more complete sentences, slower updates.",
    )
    parser.add_argument(
        "--engine", "-e",
        choices=["whisper", "parakeet", "streaming"],
        default="parakeet",
        help="Transcription engine (default: parakeet)",
    )
    parser.add_argument(
        "--vocab",
        default=None,
        help="Path to vocab.txt for parakeet engine",
    )
    parser.add_argument(
        "--v2",
        action="store_true",
        help="Use parakeet v2 (English-only, 600M)",
    )
    parser.add_argument(
        "--v3",
        action="store_true",
        help="Use parakeet v3 (multilingual, 600M) [default]",
    )
    parser.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="Suppress all non-transcript output (stderr). Only transcription text goes to stdout.",
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="Write transcript to a file (appends, useful for tailing).",
    )
    args = parser.parse_args()

    if args.quiet:
        sys.stderr = open(os.devnull, "w")
        os.environ["WHISPER_TERM_QUIET"] = "1"

    if args.output:
        # Redirect stdout to file (append mode, line-buffered)
        sys.stdout = open(args.output, "a", buffering=1)
        print(f"--- Session started {time.strftime('%Y-%m-%d %H:%M:%S')} ---", flush=True)

    import glob as globmod

    engine = args.engine
    model_path = args.model
    vocab_path = args.vocab or ""

    if engine == "streaming":
        # Auto-detect EOU model and vocab
        if model_path is None:
            candidates = [
                "parakeet.cpp/models/model-eou.safetensors",
                "models/model-eou.safetensors",
            ]
            for c in candidates:
                if os.path.exists(c):
                    model_path = c
                    break
            if model_path is None:
                print("Error: EOU model not found. Run convert_nemo.py with --model eou-120m first.", file=sys.stderr)
                sys.exit(1)
        if not vocab_path:
            candidates = [
                "parakeet.cpp/models/vocab-eou.txt",
                "models/vocab-eou.txt",
            ]
            for c in candidates:
                if os.path.exists(c):
                    vocab_path = c
                    break
            if not vocab_path:
                print("Error: EOU vocab not found.", file=sys.stderr)
                sys.exit(1)

        print(f"Engine: streaming EOU | Model: {model_path}", file=sys.stderr)
        if args.mic:
            run_mic_streaming(model_path, vocab_path)
        else:
            run_streaming_mode(model_path, vocab_path)
        return

    if engine == "parakeet":
        # Determine version: --v2 flag, or default to v3
        use_v2 = args.v2 and not args.v3

        if model_path is None:
            if use_v2:
                candidates = [
                    "parakeet.cpp/models/model-600m.safetensors",
                    "models/model-600m.safetensors",
                ]
            else:
                candidates = [
                    "parakeet.cpp/models/model-600m-v3.safetensors",
                    "models/model-600m-v3.safetensors",
                    "parakeet.cpp/models/model-600m.safetensors",
                    "models/model-600m.safetensors",
                ]
            for c in candidates:
                if os.path.exists(c):
                    model_path = c
                    break
            if model_path is None:
                print("Error: parakeet model not found. Run convert_nemo.py first.", file=sys.stderr)
                sys.exit(1)
        if not vocab_path:
            if use_v2:
                candidates = [
                    "parakeet.cpp/models/vocab-600m.txt",
                    "models/vocab-600m.txt",
                ]
            else:
                candidates = [
                    "parakeet.cpp/models/vocab-v3.txt",
                    "models/vocab-v3.txt",
                    "parakeet.cpp/models/vocab-600m.txt",
                    "models/vocab-600m.txt",
                ]
            for c in candidates:
                if os.path.exists(c):
                    vocab_path = c
                    break
            if not vocab_path:
                print("Error: vocab.txt not found. Run extract_vocab.py first.", file=sys.stderr)
                sys.exit(1)
    else:
        # Auto-detect whisper model
        if model_path is None:
            candidates = [
                "models/ggml-base.en.bin",
                "models/ggml-small.en.bin",
            ] + globmod.glob("/opt/homebrew/share/whisper-cpp/models/ggml-*.bin")
            for c in candidates:
                if os.path.exists(c):
                    model_path = c
                    break
            if model_path is None:
                model_path = "models/ggml-base.en.bin"

    print(f"Engine: {engine} | Model: {model_path}", file=sys.stderr)
    print(f"Chunk: {args.chunk}s | Language: {args.language}", file=sys.stderr)

    if args.mic:
        if engine == "parakeet":
            if "v3" in model_path:
                model_type = "tdt-600m"
            elif "600m" in model_path:
                model_type = "tdt-600m-v2"
            else:
                model_type = "tdt-ctc-110m"
            run_mic_persistent(model_path, vocab_path, model_type, args.chunk)
        else:
            run_mic_mode(model_path, args.language, args.timestamps, args.chunk)
    else:
        if engine == "parakeet":
            if "v3" in model_path:
                model_type = "tdt-600m"
            elif "600m" in model_path:
                model_type = "tdt-600m-v2"
            else:
                model_type = "tdt-ctc-110m"
            run_stdin_persistent(model_path, vocab_path, model_type, args.chunk)
        else:
            run_stdin_mode(model_path, args.language, args.timestamps, args.chunk, engine, vocab_path)


if __name__ == "__main__":
    main()
