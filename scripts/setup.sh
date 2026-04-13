#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

echo "=== whisper-term setup ==="

# 1. Clone and build parakeet.cpp
if [ ! -d "parakeet.cpp" ]; then
    echo "Cloning parakeet.cpp..."
    git clone --recursive https://github.com/Frikallo/parakeet.cpp.git
else
    echo "parakeet.cpp already exists, skipping clone"
fi

# Apply patches: add our server example
echo "Installing parakeet-server..."
mkdir -p parakeet.cpp/examples/server
cp parakeet-server/main.cpp parakeet.cpp/examples/server/
cp parakeet-server/CMakeLists.txt parakeet.cpp/examples/server/

# Add server to examples CMakeLists if not already there
if ! grep -q "server" parakeet.cpp/examples/CMakeLists.txt 2>/dev/null; then
    echo "add_subdirectory(server)" >> parakeet.cpp/examples/CMakeLists.txt
fi

# Apply blank_id fix and v2 config patch
BLANK_PATCH="$ROOT/patches/parakeet-blank-id-v2.patch"
if [ -f "$BLANK_PATCH" ]; then
    cd parakeet.cpp
    git apply --check "$BLANK_PATCH" 2>/dev/null && git apply "$BLANK_PATCH" && echo "Applied blank_id/v2 patch" || echo "Patch already applied or not needed"
    cd "$ROOT"
fi

# Fix atomics detection for macOS
ATOMICS_CMAKE="parakeet.cpp/third_party/axiom/third_party/highway/cmake/FindAtomics.cmake"
if [ -f "$ATOMICS_CMAKE" ] && ! grep -q "APPLE.*return" "$ATOMICS_CMAKE"; then
    sed -i '' '1i\
if(APPLE)\
  return()\
endif()\
' "$ATOMICS_CMAKE"
    echo "Patched FindAtomics.cmake for macOS"
fi

# Build parakeet.cpp
echo "Building parakeet.cpp..."
cd parakeet.cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(sysctl -n hw.ncpu)
cd "$ROOT"

# Install binaries
echo "Installing binaries..."
mkdir -p ~/.local/bin
cp parakeet.cpp/build/parakeet ~/.local/bin/parakeet
cp parakeet.cpp/build/examples/server/parakeet-server ~/.local/bin/parakeet-server

# 2. Download and convert models
echo "Downloading parakeet model..."
mkdir -p models
cd parakeet.cpp

# v3 model (multilingual, default)
if [ ! -f "models/model-600m-v3.safetensors" ]; then
    huggingface-cli download nvidia/parakeet-tdt-0.6b-v3 --include "*.nemo" --local-dir models
    pip install safetensors torch
    python scripts/convert_nemo.py models/parakeet-tdt-0.6b-v3.nemo -o models/model-600m-v3.safetensors --model 600m-tdt
    python scripts/extract_vocab.py models/parakeet-tdt-0.6b-v3.nemo -o models/vocab-v3.txt
    echo "v3 model converted"
else
    echo "v3 model already exists"
fi

# v2 model (English-only)
if [ ! -f "models/model-600m.safetensors" ]; then
    huggingface-cli download nvidia/parakeet-tdt-0.6b-v2 --include "*.nemo" --local-dir models
    python scripts/convert_nemo.py models/parakeet-tdt-0.6b-v2.nemo -o models/model-600m.safetensors --model 600m-tdt
    python scripts/extract_vocab.py models/parakeet-tdt-0.6b-v2.nemo -o models/vocab-600m.txt
    echo "v2 model converted"
else
    echo "v2 model already exists"
fi

cd "$ROOT"

# 3. Build audiocapture (Swift)
echo "Building audiocapture..."
make build-swift

# 4. Install Python package
echo "Installing whisper-term..."
pip install -e .

echo ""
echo "=== Setup complete ==="
echo "Usage:"
echo "  whisper-term --mic                              # Mic transcription"
echo "  audiocapture/.build/release/audiocapture --app <bundle-id> | whisper-term  # App capture"
