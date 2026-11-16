#!/bin/bash
# 构建、签名，并在成功后用新 App 替换正在运行的 VoiceInput。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export OPEN=1
exec "$ROOT/scripts/build_app.sh"
