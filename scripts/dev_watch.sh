#!/bin/bash
# 监听会影响 App 的文件，停止修改后重新构建并重启 VoiceInput。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${WATCH_INTERVAL:-1}"
DEBOUNCE="${WATCH_DEBOUNCE:-0.5}"

source_signature() {
    local paths=()
    local path file
    for path in "$ROOT/Package.swift" "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Support" "$ROOT/scripts"; do
        [ -e "$path" ] && paths+=("$path")
    done

    while IFS= read -r -d '' file; do
        stat -f '%Fm|%z|%N' "$file"
    done < <(find "${paths[@]}" -type f ! -name '.DS_Store' -print0) \
        | LC_ALL=C sort \
        | shasum -a 256 \
        | awk '{print $1}'
}

rebuild() {
    echo "==> 检测到源码变化，重新构建并启动"
    if "$ROOT/scripts/dev_restart.sh"; then
        return 0
    fi
    echo "构建失败；当前 VoiceInput 保持运行，修复后会自动重试。" >&2
    return 1
}

trap 'echo; echo "已停止监听。"; exit 0' INT TERM

last_signature="$(source_signature)"
if [ "${WATCH_INITIAL_BUILD:-1}" = "1" ]; then
    rebuild || true
    last_signature="$(source_signature)"
fi

echo "==> 正在监听 Sources、Tests、Support、scripts 和 Package.swift"
echo "    修改保存后会自动构建并重启；按 Control-C 停止。"

while true; do
    sleep "$INTERVAL"
    current_signature="$(source_signature)"
    if [ "$current_signature" = "$last_signature" ]; then
        continue
    fi

    # 连续编辑时等待文件状态稳定，避免每保存一个文件就构建一次。
    while true; do
        sleep "$DEBOUNCE"
        next_signature="$(source_signature)"
        if [ "$next_signature" = "$current_signature" ]; then
            break
        fi
        current_signature="$next_signature"
    done

    last_signature="$current_signature"
    rebuild || true
done
