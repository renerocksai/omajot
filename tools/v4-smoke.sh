#!/bin/sh
# Model.mjs must also run in Qt's own JS engine (V4), not only in node:
# V4 rejects syntax node accepts, such as \p{…} escapes in regexes.
cd "$(dirname "$0")/.." || exit 1
if QT_QPA_PLATFORM=offscreen timeout 30 /usr/lib/qt6/bin/qml tests/v4-smoke.qml >/dev/null 2>&1; then
  echo "V4 smoke: pass"
else
  echo "V4 smoke: FAIL (run: QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml tests/v4-smoke.qml)"
  exit 1
fi
