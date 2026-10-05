#!/bin/bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$(mktemp -d)/session_gate_test"
trap 'rm -rf "$(dirname "$BIN")"' EXIT

clang++ -std=c++17 -Wall -Wextra -Werror -I"$IOS_DIR/src" "$IOS_DIR/tests/session_gate_test.cpp" -o "$BIN"
"$BIN"
