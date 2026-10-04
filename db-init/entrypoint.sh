#!/bin/bash
set -euo pipefail

# --- Configuration defaults and validation ---
DB_LOGIN="${DB_LOGIN:-bfa_auth}"
DB_WORLD="${DB_WORLD:-bfa_world}"
DB_CHAR="${DB_CHAR:-bfa_characters}"
DB_HOTFIX="${DB_HOTFIX:-bfa_hotfixes}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
WORLD_IP="${WORLD_IP:-}"
WORLD_NAME="${WORLD_NAME:-}"

: "${DB_USER:?Environment variable DB_USER must be set}"
: "${DB_PASSWORD:?Environment variable DB_PASSWORD must be set}"
: "${DB_ROOT_PASSWORD:?Environment variable DB_ROOT_PASSWORD must be set}"

export MYSQL_PWD="${DB_ROOT_PASSWORD}"

MARKER_DIR="${INIT_MARKER_DIR:-/var/lib/havencore-init}"
MARKER_FILE="${MARKER_DIR}/initialized"
SQL_DIR="${SQL_BASE_DIR:-/opt/havencore}"
TIMEOUT_SECONDS="${DB_TIMEOUT_SECONDS:-180}"

# Ensure marker directory exists
mkdir -p "${MARKER_DIR}"

# --- Logging helpers ---
log(){
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

die(){
    log "ERROR: $1" >&2
    exit "${2:-1}"
}

# --- Database client detection ---
determine_db_command(){
    if command -v mariadb >/dev/null 2>&1; then
        DB_CLIENT="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        DB_CLIENT="mysql"
    else
        die "Neither mariadb nor mysql was found."
    fi
    log "Using database client: ${DB_CLIENT}"
}

mysql_exec(){
    local database="${1}"
    shift
    "${DB_CLIENT}" \
        -h "${DB_HOST}" \
        -P "${DB_PORT}" \
        -u root \
        "${database}" \
        "$@"
}

mysql_admin(){
    "${DB_CLIENT}" \
        -h "${DB_HOST}" \
        -P "${DB_PORT}" \
        -u root \
        "$@"
}

# --- Wait for database connectivity ---
wait_for_db() {
    log "Waiting for Database at ${DB_HOST}:${DB_PORT}..."
    local deadline
    deadline=$(( SECONDS + TIMEOUT_SECONDS ))
    while (( SECONDS < deadline )); do
        if mysql_admin -e "SELECT 1" &>/dev/null; then
            log "Database is ready."
            return 0
        fi
        sleep 2
    done
    die "Database did not become ready within ${TIMEOUT_SECONDS} seconds."
}

# --- Database creation and privileges ---
create_world_db(){
    log "Creating world database: ${DB_WORLD}"
    mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${DB_WORLD}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

create_char_db(){
    log "Creating character database: ${DB_CHAR}"
    mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${DB_CHAR}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

create_auth_db(){
    log "Creating realm database: ${DB_LOGIN}"
    mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${DB_LOGIN}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

create_hotfix_db(){
    log "Creating hotfix database: ${DB_HOTFIX}"
    mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${DB_HOTFIX}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

grant_privileges(){
    mysql_admin -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
                    ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
                    GRANT ALL PRIVILEGES ON \`${DB_LOGIN}\`.* TO '${DB_USER}'@'%';
                    GRANT ALL PRIVILEGES ON \`${DB_WORLD}\`.* TO '${DB_USER}'@'%';
                    GRANT ALL PRIVILEGES ON \`${DB_CHAR}\`.* TO '${DB_USER}'@'%';
                    GRANT ALL PRIVILEGES ON \`${DB_HOTFIX}\`.* TO '${DB_USER}'@'%';
                    FLUSH PRIVILEGES;"
}

# --- Refresh realmlist address/name when WORLD_IP/WORLD_NAME is provided ---
refresh_realmlist(){
    if [ -z "${WORLD_IP}" ] && [ -z "${WORLD_NAME}" ]; then
        return 0
    fi

    local set_clause=""
    if [ -n "${WORLD_IP}" ]; then
        log "Updating realmlist address to: ${WORLD_IP}"
        set_clause="\`address\` = '${WORLD_IP}'"
    fi
    if [ -n "${WORLD_NAME}" ]; then
        log "Updating realmlist name to: ${WORLD_NAME}"
        if [ -n "${set_clause}" ]; then
            set_clause="${set_clause}, \`name\` = '${WORLD_NAME}'"
        else
            set_clause="\`name\` = '${WORLD_NAME}'"
        fi
    fi

    mysql_exec "${DB_LOGIN}" -e "UPDATE \`realmlist\` SET ${set_clause};"
}

# --- Apply database updates idempotently ---
apply_db_updates(){
    local db="${1}"
    local dir="${2}"
    local marker_file="${MARKER_DIR}/${db}_updates"
    local db_dir="${db#bfa_}"
    local updates_dir="${dir}/updates/${db_dir}"

    touch "${marker_file}"

    if [ ! -d "${updates_dir}" ]; then
        log "No updates directory found for ${db}"
        return 0
    fi

    log "Applying updates for ${db}"
    local file
    for file in "${updates_dir}"/*.sql; do
        # If no SQL files exist, the glob will not expand; skip silently.
        [ -e "${file}" ] || continue

        local filename
        filename=$(basename "${file}")
        if grep -qxF "${filename}" "${marker_file}" 2>/dev/null; then
            continue
        fi
        log "Applying update: ${filename}"
        mysql_exec "${db}" < "${file}"
        printf '%s\n' "${filename}" >> "${marker_file}"
    done
}

apply_all_db_updates(){
    local d
    for d in "${DB_LOGIN}" "${DB_WORLD}" "${DB_CHAR}" "${DB_HOTFIX}"; do
        apply_db_updates "${d}" "${SQL_DIR}"
    done
}

# --- Import base SQL files ---
import_base_sql(){
    local file
    local db

    declare -A base_files=(
        ["${DB_LOGIN}"]="${SQL_DIR}/base/bfa_auth.sql"
        ["${DB_CHAR}"]="${SQL_DIR}/base/bfa_characters.sql"
        ["${DB_WORLD}"]="${SQL_DIR}/base/bfa_world.sql"
        ["${DB_HOTFIX}"]="${SQL_DIR}/base/bfa_hotfixes.sql"
    )

    for db in "${!base_files[@]}"; do
        file="${base_files[$db]}"
        [ -f "${file}" ] || die "Required SQL file not found: ${file}. Please get them from: https://github.com/HavenWoW/BFA-HavenCore/releases/latest"
        log "Importing SQL: ${file}"
        mysql_exec "${db}" < "${file}"
    done

}

# --- Main ---
log "Starting database setup"
log "Host:       ${DB_HOST}"
log "Port:       ${DB_PORT}"
log "User:       ${DB_USER}"
log "Login DB:   ${DB_LOGIN}"
log "World DB:   ${DB_WORLD}"
log "Char DB:    ${DB_CHAR}"
log "Hotfix DB:  ${DB_HOTFIX}"

if [ -n "${WORLD_IP}" ]; then
    log "World IP:   ${WORLD_IP}"
fi
if [ -n "${WORLD_NAME}" ]; then
    log "World Name: ${WORLD_NAME}"
fi

determine_db_command

if [ -f "${MARKER_FILE}" ]; then
    log "Database already initialized, skipping setup"
    log "Checking for database updates"
    wait_for_db
    grant_privileges
    refresh_realmlist
    apply_all_db_updates
    exit 0
fi

wait_for_db

create_world_db
create_char_db
create_auth_db
create_hotfix_db
grant_privileges

import_base_sql
touch "${MARKER_FILE}"

refresh_realmlist

log "Applying database updates"
apply_all_db_updates

log "Import complete"
