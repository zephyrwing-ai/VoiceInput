#!/bin/bash
# 把 Swift Package 的编译产物打包成 VoiceInput.app 并签名。
#
# 用法：
#   ./scripts/build_app.sh                              # release + 自动选择稳定的本地签名身份
#   SIGN_IDENTITY="VoiceInput Dev" ./scripts/build_app.sh   # 指定其他固定签名身份
#   CONFIG=debug ./scripts/build_app.sh
#   OPEN=1 ./scripts/build_app.sh                       # 构建成功后替换正在运行的 App
#   FORCE_CLEAN=1 ./scripts/build_app.sh                # 强制重置 SwiftPM 构建缓存
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
BUILD_ROOT_MARKER="$ROOT/.build/.voiceinput-project-root"

project_root_from_plan() {
    local plan="$1"
    [ -f "$plan" ] || return 0
    sed -n 's|^  "\(.*\)/Sources/VoiceInput/":$|\1|p' "$plan" | head -n 1
}

build_cache_needs_reset() {
    local plan plan_root
    if [ -f "$BUILD_ROOT_MARKER" ]; then
        plan_root="$(cat "$BUILD_ROOT_MARKER" 2>/dev/null || true)"
        if [ -n "$plan_root" ] && [ "$plan_root" != "$ROOT" ]; then
            return 0
        fi
    fi
    for plan in "$ROOT/.build/debug.yaml" "$ROOT/.build/release.yaml"; do
        plan_root="$(project_root_from_plan "$plan")"
        if [ -n "$plan_root" ] && [ "$plan_root" != "$ROOT" ]; then
            return 0
        fi
    done
    return 1
}

prepare_build_cache() {
    if [ "${FORCE_CLEAN:-0}" = "1" ]; then
        echo "==> 强制重置 SwiftPM 构建缓存"
        swift package reset
    elif build_cache_needs_reset; then
        echo "==> 项目目录已变化，重置旧的 SwiftPM 构建缓存"
        swift package reset
    fi
    mkdir -p "$ROOT/.build"
    printf '%s\n' "$ROOT" > "$BUILD_ROOT_MARKER"
}

running_app_pids() {
    pgrep -x VoiceInput 2>/dev/null || true
}

wait_for_app_exit() {
    local attempts="$1"
    while [ "$attempts" -gt 0 ]; do
        if [ -z "$(running_app_pids)" ]; then
            return 0
        fi
        sleep 0.1
        attempts=$((attempts - 1))
    done
    return 1
}

stop_running_app() {
    local pids
    pids="$(running_app_pids)"
    if [ -z "$pids" ]; then
        return 0
    fi

    echo "==> 停止旧 VoiceInput 进程：$(echo "$pids" | tr '\n' ' ')"
    kill -TERM $pids 2>/dev/null || true
    if wait_for_app_exit 50; then
        return 0
    fi

    echo "==> 旧进程未在 5 秒内退出，发送 SIGKILL" >&2
    pids="$(running_app_pids)"
    [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
    if wait_for_app_exit 20; then
        return 0
    fi

    echo "旧 VoiceInput 进程无法退出，保留现有 App。" >&2
    return 1
}

launch_app() {
    local attempts=50 pid
    open "$APP"
    while [ "$attempts" -gt 0 ]; do
        pid="$(running_app_pids | head -n 1)"
        if [ -n "$pid" ]; then
            echo "==> 已启动 VoiceInput（PID ${pid}）"
            return 0
        fi
        sleep 0.1
        attempts=$((attempts - 1))
    done
    echo "App 已提交启动，但 5 秒内没有检测到 VoiceInput 进程。" >&2
    return 1
}

cd "$ROOT"
prepare_build_cache
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
    # 只有新 App 已完成编译、打包、签名和校验后，才替换旧进程。
    stop_running_app
    launch_app
fi
