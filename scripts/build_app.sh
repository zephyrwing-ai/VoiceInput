#!/bin/bash
# 把 Swift Package 的编译产物打包成 VoiceInput.app 并签名。
#
# 用法：
#   ./scripts/build_app.sh                              # release + 自动选择稳定的本地签名身份
#   SIGN_IDENTITY="VoiceInput Dev" ./scripts/build_app.sh   # 指定其他固定签名身份
#   CONFIG=debug ./scripts/build_app.sh
#   OPEN=1 ./scripts/build_app.sh                       # 打包后直接启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
DEFAULT_IDENTITY="Rig Local Development"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    IDENTITY="$SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$DEFAULT_IDENTITY"; then
    IDENTITY="$DEFAULT_IDENTITY"
else
    IDENTITY="-"
    echo "警告：没有找到稳定签名身份，本次使用 ad-hoc；重新编译后 macOS 可能要求重新授权。" >&2
fi
BUNDLE_ID="${BUNDLE_ID:-com.manus.voiceinput}"
APP="$ROOT/build/VoiceInput.app"

cd "$ROOT"
echo "==> 编译（${CONFIG}）"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceInput" "$APP/Contents/MacOS/VoiceInput"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" "$ROOT/Support/Info.plist" > "$APP/Contents/Info.plist"

if [ -f "$ROOT/Support/whisper-server" ]; then
    cp "$ROOT/Support/whisper-server" "$APP/Contents/Resources/whisper-server"
    chmod +x "$APP/Contents/Resources/whisper-server"
fi
for license in LICENSE.whisper.cpp LICENSE.whisper; do
    if [ -f "$ROOT/Support/$license" ]; then
        cp "$ROOT/Support/$license" "$APP/Contents/Resources/$license"
    fi
done

echo "==> 签名（${IDENTITY}）"
if [ -f "$APP/Contents/Resources/whisper-server" ]; then
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - "$APP/Contents/Resources/whisper-server"
    else
        codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
            "$APP/Contents/Resources/whisper-server"
    fi
fi
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --entitlements "$ROOT/Support/VoiceInput.entitlements" "$APP"
else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
        --entitlements "$ROOT/Support/VoiceInput.entitlements" "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "==> 完成：${APP}"
if [ "${OPEN:-0}" = "1" ]; then
    pkill -x VoiceInput 2>/dev/null || true
    open "$APP"
fi
