#!/usr/bin/env bash
set -euo pipefail

HAVENCORE_HOME="${HAVENCORE_HOME:-/opt/havencore}"

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-havencore}"
DB_PASSWORD="${DB_PASSWORD:-havencore}"
DB_LOGIN="${DB_LOGIN:-bfa_auth}"
DB_WORLD="${DB_WORLD:-bfa_world}"
DB_CHAR="${DB_CHAR:-bfa_characters}"
DB_HOTFIX="${DB_HOTFIX:-bfa_hotfixes}"

DB_INFO() {
  local db="$1"
  printf '%s;%s;%s;%s;%s' "${DB_HOST}" "${DB_PORT}" "${DB_USER}" "${DB_PASSWORD}" "${db}"
}

set_conf() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${HAVENCORE_HOME}/etc/${file}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${HAVENCORE_HOME}/etc/${file}"
  else
    printf '\n%s = %s\n' "${key}" "${value}" >> "${HAVENCORE_HOME}/etc/${file}"
  fi
}

ensure_conf() {
  local conf="$1"
  if [[ ! -f "${HAVENCORE_HOME}/etc/${conf}" ]]; then
    if [[ ! -f "${HAVENCORE_HOME}/etc.dist/${conf}.dist" ]]; then
      echo "Missing config template: ${conf}.dist" >&2
      exit 1
    fi
    cp "${HAVENCORE_HOME}/etc.dist/${conf}.dist" "${HAVENCORE_HOME}/etc/${conf}"
  fi
}


ROLE="${1:-worldserver}"
shift || true

case "${ROLE}" in
  bnetserver)
    ensure_conf bnetserver.conf
    set_conf "bnetserver.conf" "LoginDatabaseInfo" "\"$(DB_INFO "${DB_LOGIN}")\""
    echo "Starting bnetserver..."
    exec "${HAVENCORE_HOME}/bin/bnetserver" -c "${HAVENCORE_HOME}/etc/bnetserver.conf" "$@"
    ;;
  worldserver)
    ensure_conf worldserver.conf
    for i in "${HAVENCORE_HOME}"/etc.dist/*.conf.dist; do
        conf="$(basename "${i}")"
        conf="${conf%.dist}"
        ensure_conf "${conf}"
    done
    set_conf "worldserver.conf" "LoginDatabaseInfo" "\"$(DB_INFO "${DB_LOGIN}")\""
    set_conf "worldserver.conf" "WorldDatabaseInfo" "\"$(DB_INFO "${DB_WORLD}")\""
    set_conf "worldserver.conf" "CharacterDatabaseInfo" "\"$(DB_INFO "${DB_CHAR}")\""
    set_conf "worldserver.conf" "HotfixDatabaseInfo" "\"$(DB_INFO "${DB_HOTFIX}")\""
    set_conf "worldserver.conf" "Updates.EnableDatabases" "0"
    set_conf "worldserver.conf" "DataDir" "${HAVENCORE_HOME}/data"
    set_conf "worldserver.conf" "LogsDir" "${HAVENCORE_HOME}/logs"

    RUN_DIR="${HAVENCORE_HOME}/run"
    FIFO="${WORLDSERVER_FIFO:-${RUN_DIR}/worldserver.in}"
    mkdir -p "$(dirname "${FIFO}")"
    rm -f "${FIFO}"
    echo "Starting worldserver (console FIFO: ${FIFO})..."
    exec bash -c '
      set -euo pipefail
      FIFO="$1"
      HAVENCORE_HOME="$2"
      shift 2
      mkfifo "${FIFO}"
      exec 3<>"${FIFO}"
      exec "${HAVENCORE_HOME}/bin/worldserver" -c "${HAVENCORE_HOME}/etc/worldserver.conf" "$@" <&3
    ' bash "${FIFO}" "${HAVENCORE_HOME}" "$@"
    ;;
  extractors)
      cd /client

      echo "Extracting maps..."
      "${HAVENCORE_HOME}/bin/mapextractor"
      echo "Extracting vmap4..."
      "${HAVENCORE_HOME}/bin/vmap4extractor"
      echo "Assembling vmap4..."
      "${HAVENCORE_HOME}/bin/vmap4assembler" Buildings vmaps
      echo "Generating mmaps..."
      "${HAVENCORE_HOME}/bin/mmaps_generator"

      echo "Syncing maps..."
      mv maps dbc vmaps mmaps cameras db2 Buildings gt "${HAVENCORE_HOME}/data"
      echo "Maps extracted successfully."
    ;;
  bash)
    exec bash "$@"
    ;;
  sh)
    exec sh "$@"
    ;;
  *)
    echo "Unknown role: ${ROLE}" >&2
    echo "Usage: entrypoint.sh {bnetserver|worldserver|extractors|bash|sh}" >&2
    exit 1
    ;;
esac
