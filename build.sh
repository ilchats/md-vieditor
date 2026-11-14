#!/bin/bash
# Сборка и установка «MD Vieditor».
# Запуск в Терминале из папки проекта:  bash build.sh
# Нужны Command Line Tools от Apple (swiftc). Готовая программа: ~/Applications/MD Vieditor.app
#
# Все переменные записаны в виде ${ИМЯ}: встроенный в macOS bash 3.2 иначе может
# принять соседний русский символ или кавычку-ёлочку за часть имени переменной.

set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
[ -n "${KIT}" ] && [ -f "${KIT}/MDVieditor.swift" ] && [ -f "${KIT}/web/editor.html" ] \
  || { echo "Не найдена папка с исходниками"; exit 1; }

APP_NAME="MD Vieditor"
EXECUTABLE="MDVieditor"
BUILD="${KIT}/build"
APP="${BUILD}/${APP_NAME}.app"
DEST_DIR="${HOME}/Applications"
DEST="${DEST_DIR}/${APP_NAME}.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

exec > >(tee "${KIT}/build.log") 2>&1

echo "== Сборка ${APP_NAME}: $(date)"
sw_vers 2>/dev/null
echo "Процессор: $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
  echo
  echo "Не найдены инструменты разработчика Apple (Command Line Tools)."
  echo "Сейчас откроется окно их установки. После установки запустите эту же команду ещё раз."
  xcode-select --install
  exit 1
fi
swiftc --version || { echo "== ОШИБКА: swiftc не запускается"; exit 1; }

if pgrep -x "${EXECUTABLE}" >/dev/null; then
  echo
  echo "== ${APP_NAME} сейчас открыт. Закройте его (⌘Q) и запустите команду ещё раз."
  exit 1
fi

echo "== Подготовка пакета программы"
rm -rf "${BUILD}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources/en.lproj"
cp "${KIT}/Info.plist" "${APP}/Contents/Info.plist"
cp "${KIT}/AppIcon.icns" "${KIT}/THIRD-PARTY-LICENSES.txt" "${APP}/Contents/Resources/"
ditto "${KIT}/web" "${APP}/Contents/Resources/web" || { echo "== ОШИБКА копирования редактора"; exit 1; }
printf 'APPL????' > "${APP}/Contents/PkgInfo"
plutil -lint "${APP}/Contents/Info.plist" || { echo "== ОШИБКА в Info.plist"; exit 1; }

ARCH="$(uname -m)"
echo "== Компиляция (${ARCH})"
if ! swiftc -O -parse-as-library -module-name "${EXECUTABLE}" \
     -target "${ARCH}-apple-macos14.0" \
     "${KIT}/MDVieditor.swift" \
     -o "${APP}/Contents/MacOS/${EXECUTABLE}" \
     -framework Cocoa -framework WebKit; then
  echo "== ОШИБКА компиляции (подробности выше)"
  exit 1
fi

echo "== Подпись (локальная, ad-hoc)"
xattr -cr "${APP}"
codesign --force --sign - "${APP}" || { echo "== ОШИБКА подписи"; exit 1; }
codesign --verify --strict "${APP}" && echo "подпись в порядке"

echo "== Самопроверка: на несколько секунд откроется окно программы"
rm -f "${KIT}"/selftest-*.png "${KIT}/selftest-log.txt" "${KIT}/selftest-stderr.txt"
"${APP}/Contents/MacOS/${EXECUTABLE}" --selftest "${KIT}/selftest.md" "${KIT}/selftest" \
  -ApplePersistenceIgnoreState YES 2>"${KIT}/selftest-stderr.txt" &
PID=$!
for _ in $(seq 1 90); do
  kill -0 "${PID}" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "${PID}" 2>/dev/null; then
  kill "${PID}"
  echo "самопроверка не уложилась в 45 секунд"
fi
wait "${PID}" 2>/dev/null
SELFTEST_STATUS=$?
echo "код завершения самопроверки: ${SELFTEST_STATUS}"
cat "${KIT}/selftest-log.txt" 2>/dev/null

echo "== Установка в ${DEST}"
mkdir -p "${DEST_DIR}"
rm -rf "${DEST}"
ditto "${APP}" "${DEST}" || { echo "== ОШИБКА установки"; exit 1; }
"${LSREGISTER}" -u "${APP}" >/dev/null 2>&1
rm -rf "${BUILD}"
"${LSREGISTER}" -f "${DEST}" >/dev/null 2>&1

echo
echo "== Готово: ${DEST}"
echo "Программа сейчас откроется. Её можно найти в Launchpad или через Spotlight: ${APP_NAME}."
open "${DEST}"
