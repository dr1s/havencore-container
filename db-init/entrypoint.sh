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
REAPPLY_CHANGED_DATABASE_UPDATES="${REAPPLY_CHANGED_DATABASE_UPDATES:-0}"

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
create_db(){
    local db="${1}"
    log "Creating database: ${db}"
    mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`${db}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

grant_privileges(){
    local escaped_user escaped_pass
    escaped_user=$(sql_escape "${DB_USER}")
    escaped_pass=$(sql_escape "${DB_PASSWORD}")

    mysql_admin -e "CREATE USER IF NOT EXISTS '${escaped_user}'@'%' IDENTIFIED BY '${escaped_pass}';
                    ALTER USER '${escaped_user}'@'%' IDENTIFIED BY '${escaped_pass}';
                    GRANT ALL PRIVILEGES ON \`${DB_LOGIN}\`.* TO '${escaped_user}'@'%';
                    GRANT ALL PRIVILEGES ON \`${DB_WORLD}\`.* TO '${escaped_user}'@'%';
                    GRANT ALL PRIVILEGES ON \`${DB_CHAR}\`.* TO '${escaped_user}'@'%';
                    GRANT ALL PRIVILEGES ON \`${DB_HOTFIX}\`.* TO '${escaped_user}'@'%';
                    FLUSH PRIVILEGES;"
}

# --- Refresh realmlist address/name when WORLD_IP/WORLD_NAME is provided ---
refresh_realmlist(){
    if [[ -z "${WORLD_IP}" ]] && [[ -z "${WORLD_NAME}" ]]; then
        return 0
    fi

    local set_clause=""
    if [[ -n "${WORLD_IP}" ]]; then
        local escaped_ip
        escaped_ip=$(sql_escape "${WORLD_IP}")
        log "Updating realmlist address to: ${WORLD_IP}"
        set_clause="\`address\` = '${escaped_ip}'"
    fi
    if [[ -n "${WORLD_NAME}" ]]; then
        local escaped_name
        escaped_name=$(sql_escape "${WORLD_NAME}")
        log "Updating realmlist name to: ${WORLD_NAME}"
        if [[ -n "${set_clause}" ]]; then
            set_clause="${set_clause}, \`name\` = '${escaped_name}'"
        else
            set_clause="\`name\` = '${escaped_name}'"
        fi
    fi

    mysql_exec "${DB_LOGIN}" -e "UPDATE \`realmlist\` SET ${set_clause};"
}

# --- Update hash helpers ---
hash_file(){
    sha1sum "${1}" | awk '{print $1}' | tr '[:lower:]' '[:upper:]'
}

sql_escape(){
    printf '%s' "${1}" | sed "s/'/\\\\'/g"
}

# Returns "<count>\t<hash>" for the named update row.
get_update_state(){
    local db="${1}"
    local name="${2}"
    local escaped_name
    escaped_name=$(sql_escape "${name}")

    mysql_exec "${db}" -N -s -e \
        "SELECT COUNT(*), COALESCE(\`hash\`, '') FROM \`updates\` WHERE \`name\`='${escaped_name}';"
}

record_update(){
    local db="${1}"
    local name="${2}"
    local hash="${3}"
    local escaped_name escaped_hash
    escaped_name=$(sql_escape "${name}")
    escaped_hash=$(sql_escape "${hash}")

    mysql_exec "${db}" -e \
        "REPLACE INTO \`updates\` (\`name\`, \`hash\`, \`state\`, \`speed\`) VALUES ('${escaped_name}', '${escaped_hash}', 'RELEASED', 0);"
}

# Migrate the legacy per-database marker file into the updates table.
# The listed files are assumed to already be applied, so they are recorded
# without re-running them.
migrate_legacy_marker(){
    local db="${1}"
    local updates_dir="${2}"
    local marker_file="${MARKER_DIR}/${db}_updates"

    [[ -f "${marker_file}" ]] || return 0

    log "Migrating legacy marker file for ${db}"
    local filename
    while IFS= read -r filename; do
        [[ -n "${filename}" ]] || continue

        local state count
        state=$(get_update_state "${db}" "${filename}")
        count=$(printf '%s' "${state}" | cut -f1)
        [[ "${count:-0}" -eq 0 ]] || continue

        local file="${updates_dir}/${filename}"
        local hash=""
        if [[ -f "${file}" ]]; then
            hash=$(hash_file "${file}")
        else
            log "WARN: Legacy marker references missing file, recording empty hash: ${filename}"
        fi

        record_update "${db}" "${filename}" "${hash}"
    done < "${marker_file}"

    mv "${marker_file}" "${marker_file}.migrated"
    log "Legacy marker file migrated: ${marker_file}"
}

# --- Apply database updates idempotently ---
apply_db_updates(){
    local db="${1}"
    local dir="${2}"
    local db_dir="${db#bfa_}"
    local updates_dir="${dir}/updates/${db_dir}"

    if [[ ! -d "${updates_dir}" ]]; then
        log "No updates directory found for ${db}"
        return 0
    fi

    migrate_legacy_marker "${db}" "${updates_dir}"

    log "Applying updates for ${db}"
    local file filename hash state count stored_hash
    for file in "${updates_dir}"/*.sql; do
        # If no SQL files exist, the glob will not expand; skip silently.
        [[ -e "${file}" ]] || continue

        filename=$(basename "${file}")
        hash=$(hash_file "${file}")
        state=$(get_update_state "${db}" "${filename}")
        count=$(printf '%s' "${state}" | cut -f1)
        stored_hash=$(printf '%s' "${state}" | cut -f2)

        if [[ "${count:-0}" -eq 0 ]]; then
            log "Applying update: ${filename}"
            mysql_exec "${db}" < "${file}"
            record_update "${db}" "${filename}" "${hash}"
        elif [[ -z "${stored_hash}" ]]; then
            log "Re-hashing update: ${filename}"
            record_update "${db}" "${filename}" "${hash}"
        elif [[ "${stored_hash}" = "${hash}" ]]; then
            log "Update already applied and matches hash: ${filename}"
        elif [[ "${REAPPLY_CHANGED_DATABASE_UPDATES:-0}" = "1" ]]; then
            log "Reapplying changed update: ${filename}"
            mysql_exec "${db}" < "${file}"
            record_update "${db}" "${filename}" "${hash}"
        else
            log "WARN: Update ${filename} has changed (hash mismatch). Skipping. Set REAPPLY_CHANGED_DATABASE_UPDATES=1 to reapply."
        fi
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
        [[ -f "${file}" ]] || die "Required SQL file not found: ${file}. Please get them from: https://github.com/HavenWoW/BFA-HavenCore/releases/latest"
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

if [[ -n "${WORLD_IP}" ]]; then
    log "World IP:   ${WORLD_IP}"
fi
if [[ -n "${WORLD_NAME}" ]]; then
    log "World Name: ${WORLD_NAME}"
fi

determine_db_command

if [[ -f "${MARKER_FILE}" ]]; then
    log "Database already initialized, skipping setup"
    log "Checking for database updates"
    wait_for_db
    grant_privileges
    refresh_realmlist
    apply_all_db_updates
    exit 0
fi

wait_for_db

create_db "${DB_WORLD}"
create_db "${DB_CHAR}"
create_db "${DB_LOGIN}"
create_db "${DB_HOTFIX}"
grant_privileges

import_base_sql
touch "${MARKER_FILE}"

refresh_realmlist

log "Applying database updates"
apply_all_db_updates

log "Import complete"
