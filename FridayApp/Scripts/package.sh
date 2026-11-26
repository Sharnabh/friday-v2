#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
bin=$(swift build -c release --show-bin-path)
app=${1:-../outputs/Friday.app}
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Scripts/Info.plist "$app/Contents/Info.plist"
cp Scripts/Friday.icns "$app/Contents/Resources/"
cp Sources/FridayCore/Resources/*.py Sources/FridayCore/Resources/*.js "$app/Contents/Resources/"
voice_dir=${FRIDAY_WHISPER_DIR:-"$HOME/.hermes/tools/friday-whisper"}
if [ -x "$voice_dir/whisper-cli" ] && [ -f "$voice_dir/ggml-small.en.bin" ] && [ -f "$voice_dir/ggml-base.bin" ]; then
    mkdir -p "$app/Contents/Resources/Whisper"
    cp Scripts/Whisper-Cpp-LICENSE "$app/Contents/Resources/Whisper/LICENSE"
    cp Scripts/Whisper-Model-LICENSE "$app/Contents/Resources/Whisper/LICENSE-models"
    for file in whisper-cli ggml-small.en.bin ggml-base.bin; do
        cp -p "$voice_dir/$file" "$app/Contents/Resources/Whisper/$file"
    done
else
    echo "Set FRIDAY_WHISPER_DIR to a directory containing whisper-cli, ggml-small.en.bin and ggml-base.bin." >&2
    exit 1
fi
cp "$bin/Friday" "$app/Contents/MacOS/Friday.new"
mv "$app/Contents/MacOS/Friday.new" "$app/Contents/MacOS/Friday"
codesign --force --entitlements Scripts/entitlements.plist --sign - "$app"
codesign --verify --strict "$app"
