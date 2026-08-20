#!/usr/bin/env bash
#
# Cloud-to-NAS — Cloud Photo Archive Organiser
# Copyright (C) 2026 James Wintermute
#
# Licensed under the GNU General Public License v3.0 or later.
# See LICENSE or https://www.gnu.org/licenses/gpl-3.0.html
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# Version: 1.4.4
# Date:    2026-08-20
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH_DIR="${SCRIPT_DIR}/local/paths"
SOURCE_FILE="${PATH_DIR}/source.txt"
DESTINATIONS_FILE="${PATH_DIR}/nas-destinations.txt"
OLD_DESTINATION_FILE="${PATH_DIR}/nas-destination.txt"
DEFAULT_SOURCE="${SCRIPT_DIR}/cloud-IN"
TRANSFERRED_DIR="${SCRIPT_DIR}/transferred"
VAR_DIR="${SCRIPT_DIR}/var"
TRANSFER_STATE_DIR="${VAR_DIR}/transfers"
LOG_DIR="${SCRIPT_DIR}/logs"
LAST_TRANSFER_POINTER="${TRANSFER_STATE_DIR}/last-transfer.txt"
VERSION="1.4.4"
RELEASE="August 2026"
AUTHOR="James Wintermute"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

header() {
    clear

    printf '%b' "$MAGENTA"
    cat <<'EOF'
   ________                __     __           _   _____   _____
  / ____/ /___  __  ______/ /     \ \         / | / /   | / ___/
 / /   / / __ \/ / / / __  /       \ \       /  |/ / /| | \__ \ 
/ /___/ / /_/ / /_/ / /_/ /        / /      / /|  / ___ |___/ / 
\____/_/\____/\__,_/\__,_/        /_/      /_/ |_/_/  |_/____/
EOF
    echo
    echo "      Cloud photo archive organiser"
    echo
    echo "      v${VERSION} - ${RELEASE}. ${AUTHOR}"
    echo "      Host: $(hostname 2>/dev/null || echo unknown)"
    echo "      Bash: ${BASH_VERSION:-unknown}"
    printf '%b' "$NC"
    echo
}

pause() {
    echo
    read -r -p "Press Enter to continue..."
}

expand_local_path() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        path="$HOME"
    elif [[ "$path" == "~/"* ]]; then
        path="${HOME}/${path#~/}"
    fi
    printf '%s\n' "$path"
}

iso_date_from_file() {
    local path="$1"
    local mtime_epoch

    mtime_epoch=$(stat -c '%Y' -- "$path" 2>/dev/null) || return 1
    [[ "$mtime_epoch" =~ ^[0-9]+$ ]] || return 1

    LC_ALL=C date -d "@${mtime_epoch}" '+%Y-%m-%d' 2>/dev/null
}


# Emit import files recursively as NUL-delimited paths.
# Deliberately does not follow symlinked directories. Common cloud-export /
# macOS metadata is ignored so it cannot become part of the photo archive.
find_import_files() {
    local root="${1:-$SOURCE}"

    find "$root" \
        \( -type d -name '__MACOSX' -prune \) -o \
        \( -type f \
            ! -name '.gitkeep' \
            ! -name '.DS_Store' \
            ! -name 'Thumbs.db' \
            ! -name '._*' \
            -print0 \) 2>/dev/null
}

relative_to_source() {
    local path="$1"
    if [[ "$path" == "$SOURCE"/* ]]; then
        printf '%s\n' "${path#"$SOURCE"/}"
    else
        printf '%s\n' "$(basename "$path")"
    fi
}

# Files already under a top-level Cloud-to-NAS monthly folder are prepared
# archive content, not raw import material. Recursive prepare stages skip them.
is_managed_month_file() {
    local path="$1"
    local rel
    rel=$(relative_to_source "$path")
    [[ "$rel" =~ ^[0-9]{4}-[0-9]{2}-00[[:space:]]-[[:space:]][^/]+/ ]]
}

count_import_files() {
    local root="$1"
    local path count=0
    while IFS= read -r -d '' path; do
        ((count++))
    done < <(find_import_files "$root")
    printf '%d\n' "$count"
}

count_import_bytes() {
    local root="$1"
    local path size total=0
    while IFS= read -r -d '' path; do
        size=$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        ((total += size))
    done < <(find_import_files "$root")
    printf '%d\n' "$total"
}

import_max_depth() {
    local root="$1"
    local path rel slashes depth max_depth=0
    while IFS= read -r -d '' path; do
        rel="${path#"$root"/}"
        slashes="${rel//[^\/]/}"
        depth=${#slashes}
        (( depth > max_depth )) && max_depth=$depth
    done < <(find_import_files "$root")
    printf '%d\n' "$max_depth"
}

show_progress() {
    local current="$1"
    local total="$2"
    local label="${3:-Progress}"
    local percent=0
    local frame
    local frames=('|' '/' '-' '\')

    if (( total > 0 )); then
        percent=$(( current * 100 / total ))
    fi

    frame="${frames[$(( current % 4 ))]}"
    printf '\r  [%s] %s: %d/%d (%3d%%)' "$frame" "$label" "$current" "$total" "$percent"
}

clear_progress() {
    printf '\r\033[K'
}

show_activity() {
    local current="$1"
    local label="${2:-Scanning}"
    local frame
    local frames=('|' '/' '-' '\')

    frame="${frames[$(( current % 4 ))]}"
    printf '\r  [%s] %s: %d file(s)' "$frame" "$label" "$current"
}

migrate_old_config() {
    mkdir -p "$PATH_DIR" "$VAR_DIR" "$TRANSFER_STATE_DIR" "$LOG_DIR" "$TRANSFERRED_DIR"
    if [[ -f "$OLD_DESTINATION_FILE" && ! -f "$DESTINATIONS_FILE" ]]; then
        echo "Existing v1.0.0 NAS destination found."
        echo "Migrating configuration..."
        echo
        cp -- "$OLD_DESTINATION_FILE" "$DESTINATIONS_FILE"
        echo "Created:"
        echo "  $DESTINATIONS_FILE"
        echo
    fi
}

config_valid() {
    [[ -s "$SOURCE_FILE" && -s "$DESTINATIONS_FILE" ]]
}

parse_nas_destination() {
    local destination="$1"

    # Supported form: user@host:/absolute/path (or host:/absolute/path).
    # This deliberately keeps first-time configuration simple and predictable.
    if [[ "$destination" =~ ^([^:[:space:]]+):(/.*)$ ]]; then
        REMOTE_HOST="${BASH_REMATCH[1]}"
        REMOTE_PATH="${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

load_nas_destinations() {
    NAS_DESTINATIONS=()

    local destination
    while IFS= read -r destination; do
        [[ -z "$destination" ]] && continue
        [[ "$destination" =~ ^[[:space:]]*# ]] && continue
        NAS_DESTINATIONS+=("$destination")
    done < "$DESTINATIONS_FILE"
}

save_nas_destinations() {
    : > "$DESTINATIONS_FILE"

    local destination
    for destination in "${NAS_DESTINATIONS[@]}"; do
        printf '%s\n' "$destination" >> "$DESTINATIONS_FILE"
    done
}

test_single_destination() {
    local destination="$1"
    local display_number="$2"
    local probe_dir="$3"
    local remote_path_q
    local ssh_output
    local ssh_rc
    local rsync_rc

    echo "============================================================"
    echo "Destination $display_number:"
    echo "  $destination"
    echo "============================================================"

    if ! parse_nas_destination "$destination"; then
        echo -e "  ${RED}Format test: FAILED${NC}"
        echo "  Expected: user@host:/absolute/path"
        echo
        return 1
    fi

    remote_path_q=$(printf '%q' "$REMOTE_PATH")

    echo "SSH path test..."
    ssh_output=$(ssh -o ConnectTimeout=7 "$REMOTE_HOST" \
        "if [ ! -d $remote_path_q ]; then printf '%s\\n' PATH_MISSING; exit 2; elif [ ! -w $remote_path_q ]; then printf '%s\\n' PATH_NOT_WRITABLE; exit 3; else printf '%s\\n' PATH_OK; fi")
    ssh_rc=$?

    case "$ssh_rc:$ssh_output" in
        0:*PATH_OK*)
            echo -e "  SSH path test: ${GREEN}${BOLD}[Verified]${NC}"
            ;;
        2:*PATH_MISSING*)
            echo -e "  ${RED}SSH path test: FAILED${NC} - remote directory does not exist"
            echo
            return 1
            ;;
        3:*PATH_NOT_WRITABLE*)
            echo -e "  ${RED}SSH path test: FAILED${NC} - remote directory is not writable"
            echo
            return 1
            ;;
        *)
            echo -e "  ${RED}SSH path test: FAILED${NC} - connection/authentication error"
            [[ -n "$ssh_output" ]] && echo "  $ssh_output"
            echo
            return 1
            ;;
    esac

    echo
    echo "rsync simulation (dry run - nothing written)..."

    rsync -avhns --itemize-changes --timeout=15 \
        -e "ssh -o ConnectTimeout=7" \
        -- "$probe_dir/" "${destination%/}/"
    rsync_rc=$?

    if [[ "$rsync_rc" -eq 0 ]]; then
        echo -e "  rsync simulation: ${GREEN}${BOLD}[Verified]${NC}"
        echo -e "  ${GREEN}${BOLD}[Verified] Destination $display_number is ready for rsync.${NC}"
        echo
        return 0
    fi

    echo -e "  ${RED}rsync simulation: FAILED${NC} (exit code $rsync_rc)"
    echo
    return 1
}

test_nas_destinations() {
    local pause_after="${1:-1}"
    local allow_edit="${2:-1}"
    local probe_dir
    local probe_file
    local destination
    local choice
    local replacement
    local passed=0
    local failed=0
    local removed=0
    local i=0

    if [[ "$pause_after" -eq 1 ]]; then
        header
        echo -e "${CYAN}TEST NAS DESTINATION PATHS${NC}"
        echo
    else
        echo
        echo "------------------------------------------------------------"
        echo -e "${CYAN}Testing NAS destination paths${NC}"
        echo
    fi

    if [[ ! -s "$DESTINATIONS_FILE" ]]; then
        echo -e "${RED}ERROR:${NC} No NAS destinations are configured."
        [[ "$pause_after" -eq 1 ]] && pause
        return 1
    fi

    if ! command -v ssh >/dev/null 2>&1; then
        echo -e "${RED}ERROR:${NC} ssh is not installed or not in PATH."
        [[ "$pause_after" -eq 1 ]] && pause
        return 1
    fi

    if ! command -v rsync >/dev/null 2>&1; then
        echo -e "${RED}ERROR:${NC} rsync is not installed or not in PATH."
        [[ "$pause_after" -eq 1 ]] && pause
        return 1
    fi

    load_nas_destinations

    if [[ ${#NAS_DESTINATIONS[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR:${NC} No NAS destinations are configured."
        [[ "$pause_after" -eq 1 ]] && pause
        return 1
    fi

    probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/cloud-to-nas-rsync-test.XXXXXX") || {
        echo -e "${RED}ERROR:${NC} Could not create a temporary rsync test directory."
        [[ "$pause_after" -eq 1 ]] && pause
        return 1
    }

    probe_file="${probe_dir}/.cloud-to-nas-rsync-test"
    printf 'Cloud-to-NAS rsync dry-run probe. Nothing should be written remotely.\n' > "$probe_file"

    echo "The test performs two checks for each destination:"
    echo
    echo "  1. SSH connection + remote directory exists and is writable"
    echo "  2. rsync --dry-run simulation using a temporary probe file"
    echo
    echo "The rsync stage is a simulation: it does NOT write the probe file."
    echo "You may be prompted for an SSH host key or password."
    echo

    while (( i < ${#NAS_DESTINATIONS[@]} )); do
        destination="${NAS_DESTINATIONS[$i]}"

        if test_single_destination "$destination" "$((i + 1))" "$probe_dir"; then
            ((passed++))
            ((i++))
            continue
        fi

        if [[ "$allow_edit" -ne 1 ]]; then
            ((failed++))
            ((i++))
            continue
        fi

        while true; do
            echo -e "${YELLOW}Destination $((i + 1)) could not be verified.${NC}"
            echo
            echo "What would you like to do?"
            echo
            echo "  1) Edit destination"
            echo "  2) Retry test"
            echo "  3) Remove destination"
            echo "  4) Keep unverified"
            echo
            read -r -p "Selection: " choice

            case "$choice" in
                1)
                    echo
                    echo "Current:"
                    echo "  ${NAS_DESTINATIONS[$i]}"
                    echo

                    if [[ -t 0 ]]; then
                        read -e -r -i "${NAS_DESTINATIONS[$i]}" -p "New destination: " replacement
                    else
                        read -r -p "New destination: " replacement
                    fi

                    if [[ -z "$replacement" ]]; then
                        echo "Destination unchanged."
                        echo
                        continue
                    fi

                    if ! parse_nas_destination "$replacement"; then
                        echo -e "${RED}Invalid destination format.${NC}"
                        echo "Use: user@host:/absolute/path"
                        echo
                        continue
                    fi

                    NAS_DESTINATIONS[$i]="$replacement"
                    save_nas_destinations
                    echo
                    echo "Destination updated. Retesting..."
                    echo
                    break
                    ;;

                2)
                    echo
                    echo "Retrying..."
                    echo
                    break
                    ;;

                3)
                    if [[ ${#NAS_DESTINATIONS[@]} -le 1 ]]; then
                        echo
                        echo -e "${RED}At least one NAS destination is required.${NC}"
                        echo "Edit the destination or keep it unverified instead."
                        echo
                        continue
                    fi

                    unset 'NAS_DESTINATIONS[i]'
                    NAS_DESTINATIONS=("${NAS_DESTINATIONS[@]}")
                    save_nas_destinations
                    ((removed++))
                    echo
                    echo "Destination removed."
                    echo
                    choice="removed"
                    break
                    ;;

                4)
                    ((failed++))
                    echo
                    echo -e "${YELLOW}Keeping destination as unverified.${NC}"
                    echo
                    choice="keep"
                    break
                    ;;

                *)
                    echo "Invalid selection."
                    ;;
            esac
        done

        case "$choice" in
            removed)
                # Array has shifted; test the new entry at this index.
                continue
                ;;
            keep)
                ((i++))
                continue
                ;;
            *)
                # Edit or retry: test the current index again.
                continue
                ;;
        esac
    done

    rm -rf -- "$probe_dir"

    echo "------------------------------------------------------------"
    echo "NAS path test complete."
    echo "Configured : ${#NAS_DESTINATIONS[@]}"
    echo "Verified   : $passed"
    echo "Unverified : $failed"
    [[ "$removed" -gt 0 ]] && echo "Removed    : $removed"

    if [[ "$failed" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}[Verified] All configured NAS destinations passed.${NC}"
    else
        echo -e "${YELLOW}One or more destinations remain unverified.${NC}"
    fi

    [[ "$pause_after" -eq 1 ]] && pause

    [[ "$failed" -eq 0 ]]
}

first_time_run() {
    header
    mkdir -p "$PATH_DIR"

    echo -e "${CYAN}FIRST TIME RUN${NC}"
    echo
    echo "Cloud-to-NAS needs:"
    echo
    echo "  1. A local source directory"
    echo "  2. One or more NAS destination paths"
    echo
    echo "The configuration will be stored under:"
    echo
    echo "  $PATH_DIR"
    echo

    local source_input
    local destination
    local destination_count=0
    local test_answer

    # Create a ready-to-use inbox beside the application. Users can accept
    # this default or type/edit another path. In an interactive Bash shell,
    # Readline is enabled so Tab performs normal filesystem completion.
    mkdir -p -- "$DEFAULT_SOURCE"

    echo "A default cloud inbox has been created:"
    echo
    echo "  $DEFAULT_SOURCE"
    echo
    echo "Press Enter to use it, or edit/type another directory."
    echo "Tab completion is available for paths in an interactive terminal."
    echo

    while true; do
        if [[ -t 0 ]]; then
            read -e -r -i "$DEFAULT_SOURCE" -p "Local photo source path: " source_input
        else
            read -r -p "Local photo source path [$DEFAULT_SOURCE]: " source_input
            [[ -z "$source_input" ]] && source_input="$DEFAULT_SOURCE"
        fi

        source_input=$(expand_local_path "$source_input")
        [[ -z "$source_input" ]] && source_input="$DEFAULT_SOURCE"

        if [[ ! -d "$source_input" ]]; then
            echo -e "${YELLOW}Directory does not exist.${NC}"
            read -r -p "Create it? [Y/n]: " create_answer

            case "$create_answer" in
                n|N|no|NO)
                    echo
                    continue
                    ;;
                *)
                    if ! mkdir -p -- "$source_input"; then
                        echo -e "${RED}ERROR:${NC} Could not create directory:"
                        echo "  $source_input"
                        echo
                        continue
                    fi
                    ;;
            esac
        fi

        printf '%s\n' "$source_input" > "$SOURCE_FILE"
        break
    done

    echo
    echo "NAS destinations"
    echo
    echo "Expected format:"
    echo
    echo "  user@host:/absolute/path"
    echo
    echo "Examples:"
    echo
    echo "  user@10.0.0.2:/user/Photographs/Personal"
    echo "  user@10.0.0.2:/family/Photographs"
    echo
    echo "Enter one or more destinations."
    echo "Press Enter on an empty line when finished."
    echo

    : > "$DESTINATIONS_FILE"

    while true; do
        read -r -p "NAS destination $((destination_count + 1)): " destination

        if [[ -z "$destination" ]]; then
            if [[ "$destination_count" -eq 0 ]]; then
                echo -e "${RED}At least one NAS destination is required.${NC}"
                echo
                continue
            fi
            break
        fi

        if ! parse_nas_destination "$destination"; then
            echo -e "${RED}Invalid destination format.${NC}"
            echo "Use: user@host:/absolute/path"
            echo
            continue
        fi

        printf '%s\n' "$destination" >> "$DESTINATIONS_FILE"
        ((destination_count++))
    done

    echo
    echo "------------------------------------------------------------"
    echo -e "${BOLD}Configuration review${NC}"
    echo
    echo "Source:"
    echo "  $(cat "$SOURCE_FILE")"
    echo
    echo "NAS destinations:"

    local n=1
    while IFS= read -r destination; do
        [[ -z "$destination" ]] && continue
        echo "  $n) $destination"
        ((n++))
    done < "$DESTINATIONS_FILE"

    echo
    read -r -p "Test NAS destination path setup now? [Y/n]: " test_answer

    case "$test_answer" in
        n|N|no|NO)
            echo
            echo -e "${YELLOW}Path testing skipped.${NC} You can run it later from the menu."
            ;;
        *)
            # Failed destinations can be edited, retried or removed here without
            # leaving first-time setup.
            test_nas_destinations 0 1 || true
            ;;
    esac

    echo
    echo "------------------------------------------------------------"
    echo -e "${GREEN}${BOLD}Configuration complete.${NC}"
    echo
    echo "Source:"
    echo "  $(cat "$SOURCE_FILE")"
    echo
    echo "NAS destinations:"

    n=1
    while IFS= read -r destination; do
        [[ -z "$destination" ]] && continue
        echo "  $n) $destination"
        ((n++))
    done < "$DESTINATIONS_FILE"

    pause
}

configure_paths() {
    first_time_run
}

get_config() {
    if ! config_valid; then
        return 1
    fi

    SOURCE=$(grep -v '^[[:space:]]*#' "$SOURCE_FILE" | grep -v '^[[:space:]]*$' | head -n 1)

    if [[ -z "$SOURCE" ]]; then
        return 1
    fi

    if [[ ! -d "$SOURCE" ]]; then
        echo -e "${RED}ERROR:${NC} Source directory does not exist:"
        echo "  $SOURCE"
        return 1
    fi

    return 0
}

show_paths() {
    echo "Source:"
    echo "  $SOURCE"
    echo
    echo "NAS destinations:"

    local destination
    local n=1
    while IFS= read -r destination; do
        [[ -z "$destination" ]] && continue
        [[ "$destination" =~ ^[[:space:]]*# ]] && continue
        echo "  $n) $destination"
        ((n++))
    done < "$DESTINATIONS_FILE"
}

choose_destination() {
    local destinations=()
    local destination
    local choice

    while IFS= read -r destination; do
        [[ -z "$destination" ]] && continue
        [[ "$destination" =~ ^[[:space:]]*# ]] && continue
        destinations+=("$destination")
    done < "$DESTINATIONS_FILE"

    if [[ ${#destinations[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR:${NC} No NAS destinations configured."
        return 1
    fi

    echo "Available NAS destinations:"
    echo

    local i
    for i in "${!destinations[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${destinations[$i]}"
    done

    echo
    while true; do
        read -r -p "Select destination [1-${#destinations[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#destinations[@]} )); then
            SELECTED_DESTINATION="${destinations[$((choice - 1))]}"
            return 0
        fi
        echo "Invalid selection."
    done
}

rename_files() {
    local dry_run="$1"
    header

    if ! get_config; then
        echo -e "${RED}Configuration error.${NC}"
        pause
        return
    fi

    mkdir -p "$VAR_DIR"

    if [[ "$dry_run" -eq 1 ]]; then
        echo -e "${YELLOW}RENAME - DRY RUN${NC}"
    else
        echo -e "${GREEN}RENAME${NC}"
    fi

    echo
    echo "Source:"
    echo "  $SOURCE"
    echo
    echo "Nested cloud-export folders are scanned recursively."
    echo "Renames happen in place; existing monthly archive folders are skipped."
    echo

    if [[ "$dry_run" -eq 0 ]]; then
        local processed=0 skipped=0 errors=0 current=0 total=0 managed=0
        local path

        while IFS= read -r -d '' path; do
            if is_managed_month_file "$path"; then
                continue
            fi
            ((total++))
        done < <(find_import_files "$SOURCE")

        echo "Renaming files..."
        echo

        while IFS= read -r -d '' path; do
            local filename rel iso_date stem ext new_filename destination parent
            filename=$(basename "$path")
            rel=$(relative_to_source "$path")

            if is_managed_month_file "$path"; then
                ((managed++))
                continue
            fi

            ((current++))

            if [[ "$filename" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}- ]]; then
                ((skipped++))
                show_progress "$current" "$total" "Renaming"
                continue
            fi

            if ! iso_date=$(iso_date_from_file "$path"); then
                clear_progress
                echo -e "${RED}ERROR:${NC} Cannot determine date: $rel"
                ((errors++))
                show_progress "$current" "$total" "Renaming"
                continue
            fi

            if [[ ! "$iso_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                clear_progress
                echo -e "${RED}ERROR:${NC} Invalid date returned for: $rel"
                ((errors++))
                show_progress "$current" "$total" "Renaming"
                continue
            fi

            if [[ "$filename" == *.* ]]; then
                stem="${filename%.*}"
                ext="${filename##*.}"
                ext="${ext^^}"
                new_filename="${iso_date}-${stem}.${ext}"
            else
                new_filename="${iso_date}-${filename}"
            fi

            parent=$(dirname "$path")
            destination="${parent}/${new_filename}"

            if [[ -e "$destination" ]]; then
                clear_progress
                echo -e "${RED}COLLISION:${NC} $rel -> ${destination#"$SOURCE"/}"
                ((errors++))
                show_progress "$current" "$total" "Renaming"
                continue
            fi

            if mv -- "$path" "$destination"; then
                ((processed++))
            else
                clear_progress
                echo -e "${RED}ERROR:${NC} Rename failed: $rel"
                ((errors++))
            fi

            show_progress "$current" "$total" "Renaming"
        done < <(find_import_files "$SOURCE")

        clear_progress
        echo
        echo "------------------------------------------------------------"
        echo "Rename complete."
        echo "Renamed             : $processed"
        echo "Already ISO renamed : $skipped"
        echo "Managed folders     : $managed"
        echo "Errors              : $errors"

        if [[ "$errors" -eq 0 ]]; then
            echo -e "${GREEN}${BOLD}[Complete] $processed file(s) renamed successfully.${NC}"
        else
            echo -e "${RED}${BOLD}[Attention] Rename stage completed with errors.${NC}"
        fi

        pause
        return
    fi

    local scanned=0 would_rename=0 already_renamed=0 managed=0 collisions=0 errors=0
    local earliest="" latest="" timestamp plan_file sort_file attention_file
    local path filename rel iso_date stem ext new_filename destination new_rel month_key
    local analysis_current=0 analysis_total=0
    declare -A month_counts=()

    echo -e "${BOLD}Preparing rename dry-run...${NC}"
    echo
    echo "Discovering files..."
    analysis_total=$(count_import_files "$SOURCE")
    clear_progress
    printf '  Found: %d file(s)\n' "$analysis_total"
    echo
    echo "Building rename pre-flight..."

    timestamp=$(date '+%Y%m%d-%H%M%S')
    plan_file="${VAR_DIR}/rename-plan-${timestamp}.txt"
    sort_file=$(mktemp "${VAR_DIR}/.rename-sort.XXXXXX")
    attention_file=$(mktemp "${VAR_DIR}/.rename-attention.XXXXXX")
    : > "$sort_file"
    : > "$attention_file"

    while IFS= read -r -d '' path; do
        ((analysis_current++))
        show_progress "$analysis_current" "$analysis_total" "Analysing"

        filename=$(basename "$path")
        rel=$(relative_to_source "$path")

        if is_managed_month_file "$path"; then
            ((managed++))
            continue
        fi

        ((scanned++))

        if [[ "$filename" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}- ]]; then
            ((already_renamed++))
            continue
        fi

        if ! iso_date=$(iso_date_from_file "$path"); then
            ((errors++))
            {
                echo "ERROR: Cannot determine date"
                echo "  $rel"
                echo
            } >> "$attention_file"
            continue
        fi

        if [[ ! "$iso_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            ((errors++))
            {
                echo "ERROR: Invalid date"
                echo "  $rel"
                echo
            } >> "$attention_file"
            continue
        fi

        if [[ "$filename" == *.* ]]; then
            stem="${filename%.*}"
            ext="${filename##*.}"
            ext="${ext^^}"
            new_filename="${iso_date}-${stem}.${ext}"
        else
            new_filename="${iso_date}-${filename}"
        fi

        destination="$(dirname "$path")/${new_filename}"
        new_rel="${destination#"$SOURCE"/}"

        if [[ -e "$destination" ]]; then
            ((collisions++))
            {
                echo "COLLISION:"
                echo "  $rel"
                echo "  -> $new_rel"
                echo "  Destination already exists"
                echo
            } >> "$attention_file"
            continue
        fi

        ((would_rename++))
        month_key="${iso_date:0:7}"
        month_counts["$month_key"]=$(( ${month_counts["$month_key"]:-0} + 1 ))

        [[ -z "$earliest" || "$iso_date" < "$earliest" ]] && earliest="$iso_date"
        [[ -z "$latest" || "$iso_date" > "$latest" ]] && latest="$iso_date"

        printf '%s	%s
' "$new_rel" "$rel" >> "$sort_file"
    done < <(find_import_files "$SOURCE")

    clear_progress
    echo
    echo -e "${GREEN}${BOLD}[Complete] Rename pre-flight prepared.${NC}"
    echo

    sort -t $'	' -k1,1 "$sort_file" -o "$sort_file"

    {
        echo "Cloud-to-NAS recursive rename dry-run plan"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Source: $SOURCE"
        echo
        while IFS=$'	' read -r proposed original; do
            [[ -z "$proposed" ]] && continue
            echo "$original"
            echo "  -> $proposed"
            echo
        done < "$sort_file"
    } > "$plan_file"

    echo "Recursive scan complete."
    echo
    echo "------------------------------------------------------------"
    echo -e "${BOLD}Dry run summary${NC}"
    echo
    echo "Files scanned       : $scanned"
    echo "Would rename        : $would_rename"
    echo "Already renamed     : $already_renamed"
    echo "Managed-folder files: $managed"
    echo "Collisions          : $collisions"
    echo "Errors              : $errors"
    echo "Maximum input depth : $(import_max_depth "$SOURCE")"

    if [[ -n "$earliest" ]]; then
        echo
        echo "Date range:"
        echo "  $earliest -> $latest"
    fi

    if [[ ${#month_counts[@]} -gt 0 ]]; then
        echo
        echo "Files by month:"
        while IFS=$'	' read -r key count; do
            printf '  %s : %d
' "$key" "$count"
        done < <(
            for key in "${!month_counts[@]}"; do
                printf '%s	%d
' "$key" "${month_counts[$key]}"
            done | sort
        )
    fi

    echo
    echo -e "${BOLD}Preview - first 10 changes${NC}"
    echo

    local preview_count=0 proposed original
    while IFS=$'	' read -r proposed original; do
        [[ -z "$proposed" ]] && continue
        echo "  $original"
        echo "  -> $proposed"
        echo
        ((preview_count++))
        [[ "$preview_count" -ge 10 ]] && break
    done < "$sort_file"

    if [[ "$preview_count" -eq 0 ]]; then
        echo "  No rename changes proposed."
        echo
    fi

    if [[ "$collisions" -gt 0 || "$errors" -gt 0 ]]; then
        echo "------------------------------------------------------------"
        echo -e "${RED}${BOLD}ATTENTION${NC}"
        echo
        cat "$attention_file"
    fi

    echo "Full dry-run plan:"
    echo "  ${plan_file#${SCRIPT_DIR}/}"
    echo

    rm -f -- "$sort_file" "$attention_file"

    while true; do
        echo "  v) View full plan"
        echo "  p) Page through full plan"
        echo "  Enter) Return to menu"
        echo
        read -r -p "Selection: " choice

        case "$choice" in
            v|V) echo; cat -- "$plan_file"; echo ;;
            p|P)
                if command -v less >/dev/null 2>&1; then
                    less -- "$plan_file"
                else
                    echo -e "${YELLOW}less is not installed; showing the full plan instead.${NC}"
                    cat -- "$plan_file"
                fi
                ;;
            "") return ;;
            *) echo "Invalid selection." ;;
        esac
    done
}


folder_move() {
    header

    if ! get_config; then
        echo -e "${RED}Configuration error.${NC}"
        pause
        return
    fi

    mkdir -p "$VAR_DIR"

    echo -e "${CYAN}FOLDER MOVE - MONTH PER YEAR${NC}"
    echo
    echo "Files are discovered recursively and gathered into:"
    echo
    echo "  YYYY-MM-00 - <context>"
    echo
    echo "Examples:"
    echo "  2026-08-00 - ProtonDrive"
    echo "  2026-08-00 - iCloud"
    echo "  2026-08-00 - Google Photos"
    echo

    local context="" timestamp plan_file
    timestamp=$(date '+%Y%m%d-%H%M%S')
    plan_file="${VAR_DIR}/folder-move-plan-${timestamp}.txt"

    while true; do
        if [[ -z "$context" ]]; then
            read -r -p "Folder context: " context
        fi

        if [[ -z "$context" ]]; then
            echo; echo -e "${RED}ERROR:${NC} Context cannot be empty."
            context=""
            continue
        fi

        if [[ "$context" == *"/"* ]]; then
            echo; echo -e "${RED}ERROR:${NC} Context cannot contain '/'."
            context=""
            continue
        fi

        echo
        echo -e "${BOLD}Confirm folder context${NC}"
        echo
        echo "You entered:"
        echo -e "  ${BOLD}$context${NC}"
        echo
        echo "Monthly folders will be named:"
        echo -e "  ${BOLD}YYYY-MM-00 - ${context}${NC}"
        echo
        echo "Individual files remain YYYY-MM-DD-<original-name>.EXT"
        echo
        echo "  y) Yes - build full preview"
        echo "  e) Edit context"
        echo "  n/Enter) Cancel"
        echo

        local context_choice
        read -r -p "Selection: " context_choice
        case "$context_choice" in
            y|Y|yes|YES)
                ;;
            e|E)
                echo
                echo "Current context: $context"
                read -r -p "New folder context: " context
                continue
                ;;
            ""|n|N|no|NO)
                echo
                echo "Cancelled. No pre-flight was built and no files were moved."
                pause
                return
                ;;
            *)
                echo
                echo "Invalid selection."
                pause
                continue
                ;;
        esac

        local -a move_sources=() move_folders=() move_destinations=() collision_messages=()
        local skipped=0 managed=0 collisions=0 errors=0 discovered=0 max_depth=0
        local path filename rel year month folder destination key planned_key previous_source
        local slashes depth first_component
        local preflight_current=0 preflight_total=0
        declare -A folder_counts=()
        declare -A input_counts=()
        declare -A planned_dest_source=()

        echo
        echo "Discovering files..."
        preflight_total=$(count_import_files "$SOURCE")
        printf '  Found: %d file(s)\n' "$preflight_total"
        echo
        echo "Building folder-move pre-flight..."

        while IFS= read -r -d '' path; do
            ((preflight_current++))
            show_progress "$preflight_current" "$preflight_total" "Analysing"

            filename=$(basename "$path")
            rel=$(relative_to_source "$path")

            if is_managed_month_file "$path"; then
                ((managed++))
                continue
            fi

            ((discovered++))
            slashes="${rel//[^\/]/}"
            depth=${#slashes}
            (( depth > max_depth )) && max_depth=$depth

            if [[ "$rel" == */* ]]; then
                first_component="${rel%%/*}"
            else
                first_component="(root)"
            fi
            input_counts["$first_component"]=$(( ${input_counts["$first_component"]:-0} + 1 ))

            if [[ ! "$filename" =~ ^([0-9]{4})-([0-9]{2})-[0-9]{2}- ]]; then
                ((skipped++))
                continue
            fi

            year="${BASH_REMATCH[1]}"
            month="${BASH_REMATCH[2]}"
            folder="${SOURCE}/${year}-${month}-00 - ${context}"
            destination="${folder}/${filename}"
            key="${year}-${month}"
            planned_key="${destination,,}"

            if [[ -e "$destination" ]]; then
                ((collisions++))
                collision_messages+=("$rel|${destination#"$SOURCE"/}|Destination already exists")
                continue
            fi

            if [[ -n "${planned_dest_source[$planned_key]+x}" ]]; then
                previous_source="${planned_dest_source[$planned_key]}"
                ((collisions++))
                collision_messages+=("$previous_source|$rel|${destination#"$SOURCE"/}")
                continue
            fi

            planned_dest_source["$planned_key"]="$rel"
            move_sources+=("$path")
            move_folders+=("$folder")
            move_destinations+=("$destination")
            folder_counts["$key"]=$(( ${folder_counts["$key"]:-0} + 1 ))
        done < <(find_import_files "$SOURCE")

        clear_progress
        echo
        echo -e "${GREEN}${BOLD}[Complete] Folder-move pre-flight prepared.${NC}"

        {
            echo "Cloud-to-NAS recursive folder move plan"
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Source: $SOURCE"
            echo "Context: $context"
            echo
            local i
            for i in "${!move_sources[@]}"; do
                echo "${move_sources[$i]#"$SOURCE"/}"
                echo "  -> ${move_destinations[$i]#"$SOURCE"/}"
                echo
            done
        } > "$plan_file"

        header
        echo -e "${CYAN}FOLDER MOVE - PRE-FLIGHT${NC}"
        echo
        echo "Source:"
        echo "  $SOURCE"
        echo
        echo "Folder context:"
        echo -e "  ${BOLD}$context${NC}"
        echo
        echo "------------------------------------------------------------"
        echo -e "${BOLD}Recursive import summary${NC}"
        echo
        echo "Files discovered      : $discovered"
        echo "Nested source groups  : ${#input_counts[@]}"
        echo "Maximum input depth   : $max_depth"
        echo "Files ready to move   : ${#move_sources[@]}"
        echo "Monthly folders       : ${#folder_counts[@]}"
        echo "Already managed files : $managed"
        echo "Not ISO-renamed       : $skipped"
        echo "Collisions            : $collisions"
        echo "Errors                : $errors"

        if [[ ${#input_counts[@]} -gt 0 ]]; then
            echo
            echo -e "${BOLD}Input groups${NC}"
            while IFS=$'	' read -r key count; do
                printf '  %-45s %6d files
' "$key" "$count"
            done < <(
                for key in "${!input_counts[@]}"; do
                    printf '%s	%d
' "$key" "${input_counts[$key]}"
                done | sort
            )
        fi

        if [[ ${#folder_counts[@]} -gt 0 ]]; then
            echo
            echo -e "${BOLD}Destination folders${NC}"
            while IFS=$'	' read -r key count; do
                printf '  %-35s %6d files
' "${key}-00 - ${context}" "$count"
            done < <(
                for key in "${!folder_counts[@]}"; do
                    printf '%s	%d
' "$key" "${folder_counts[$key]}"
                done | sort
            )
        fi

        echo
        echo -e "${BOLD}Preview - first 10 moves${NC}"
        echo

        local preview_file preview_count=0 src_rel dst_rel
        preview_file=$(mktemp "${VAR_DIR}/.move-preview.XXXXXX")
        local i
        for i in "${!move_sources[@]}"; do
            src_rel="${move_sources[$i]#"$SOURCE"/}"
            dst_rel="${move_destinations[$i]#"$SOURCE"/}"
            printf '%s	%s
' "$dst_rel" "$src_rel" >> "$preview_file"
        done
        sort -t $'	' -k1,1 "$preview_file" -o "$preview_file"

        while IFS=$'	' read -r dst_rel src_rel; do
            [[ -z "$dst_rel" ]] && continue
            echo "  $src_rel"
            echo "  -> $dst_rel"
            echo
            ((preview_count++))
            [[ "$preview_count" -ge 10 ]] && break
        done < "$preview_file"
        rm -f -- "$preview_file"
        [[ "$preview_count" -eq 0 ]] && { echo "  No files are ready to move."; echo; }

        if [[ "$collisions" -gt 0 ]]; then
            echo "------------------------------------------------------------"
            echo -e "${RED}${BOLD}ATTENTION - COLLISIONS${NC}"
            echo
            local msg a b c
            for msg in "${collision_messages[@]}"; do
                IFS='|' read -r a b c <<< "$msg"
                if [[ "$c" == "Destination already exists" ]]; then
                    echo "  Source:      $a"
                    echo "  Destination: $b"
                    echo "  $c"
                else
                    echo "  Source A:    $a"
                    echo "  Source B:    $b"
                    echo "  Both become: $c"
                fi
                echo
            done
            echo "Move is blocked. Cloud-to-NAS will never overwrite or invent a suffix."
            echo
        fi

        echo "Full move plan:"
        echo "  ${plan_file#${SCRIPT_DIR}/}"
        echo
        echo "Review the context, nested-source summary and destination folders before continuing."
        echo
        echo "  y) Confirm and move files"
        echo "  e) Edit folder context"
        echo "  v) View full plan"
        echo "  p) Page through full plan"
        echo "  n/Enter) Cancel"
        echo

        local choice
        read -r -p "Selection: " choice

        case "$choice" in
            e|E)
                echo; echo "Current context: $context"
                read -r -p "New folder context: " context
                continue
                ;;
            v|V) echo; cat -- "$plan_file"; echo; pause; continue ;;
            p|P)
                if command -v less >/dev/null 2>&1; then
                    less -- "$plan_file"
                else
                    echo -e "${YELLOW}less is not installed; showing the full plan instead.${NC}"
                    cat -- "$plan_file"; pause
                fi
                continue
                ;;
            y|Y|yes|YES)
                if [[ "$collisions" -gt 0 || "$errors" -gt 0 ]]; then
                    echo; echo -e "${RED}Cannot proceed while collisions or errors are present.${NC}"
                    pause; continue
                fi
                if [[ ${#move_sources[@]} -eq 0 ]]; then
                    echo; echo -e "${YELLOW}No files are ready to move.${NC}"
                    pause; return
                fi
                ;;
            ""|n|N|no|NO)
                echo; echo "Cancelled. No files were moved."
                pause; return
                ;;
            *) echo; echo "Invalid selection."; pause; continue ;;
        esac

        echo
        echo "Moving files..."
        echo

        local moved=0 move_errors=0 total=${#move_sources[@]} removed_dirs=0
        declare -A cleanup_parents=()

        for i in "${!move_sources[@]}"; do
            mkdir -p -- "${move_folders[$i]}"

            if mv -- "${move_sources[$i]}" "${move_destinations[$i]}"; then
                ((moved++))
                if [[ "$(dirname "${move_sources[$i]}")" != "$SOURCE" ]]; then
                    cleanup_parents["$(dirname "${move_sources[$i]}")"]=1
                fi
            else
                ((move_errors++))
                clear_progress
                echo -e "${RED}ERROR:${NC} Failed to move: ${move_sources[$i]#"$SOURCE"/}"
            fi

            show_progress "$((i + 1))" "$total" "Moving"
        done
        clear_progress

        # Remove only directories that were parents/ancestors of successfully
        # moved files, and only when rmdir proves they are genuinely empty.
        local parent next_parent
        for parent in "${!cleanup_parents[@]}"; do
            while [[ "$parent" == "$SOURCE"/* && "$parent" != "$SOURCE" ]]; do
                if rmdir -- "$parent" 2>/dev/null; then
                    ((removed_dirs++))
                    next_parent=$(dirname "$parent")
                    parent="$next_parent"
                else
                    break
                fi
            done
        done

        echo
        echo
        echo "------------------------------------------------------------"
        echo "Folder move complete."
        echo "Moved                 : $moved"
        echo "Empty wrappers removed: $removed_dirs"
        echo "Errors                : $move_errors"

        if [[ "$move_errors" -eq 0 && "$moved" -eq "$total" ]]; then
            echo -e "${GREEN}${BOLD}[Complete] $moved files moved into ${#folder_counts[@]} monthly folders.${NC}"
        else
            echo -e "${RED}${BOLD}[Attention] Folder move completed with errors.${NC}"
        fi

        pause
        return
    done
}


###############################################################################
# Transfer state, verification, archive and logging
###############################################################################

log_line() {
    local log_file="$1"
    shift
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file"
}

human_bytes() {
    local bytes="${1:-0}"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s bytes\n' "$bytes"
    else
        printf '%s bytes\n' "$bytes"
    fi
}

count_tree_files() {
    local root="$1"
    find "$root" -type f ! -name '.gitkeep' -printf '.' 2>/dev/null | wc -c
}

count_tree_bytes() {
    local root="$1"
    find "$root" -type f ! -name '.gitkeep' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

write_transfer_state() {
    local state_file="$1"
    {
        printf 'TRANSFER_ID\t%s\n' "$STATE_TRANSFER_ID"
        printf 'SOURCE_ROOT\t%s\n' "$STATE_SOURCE_ROOT"
        printf 'LOCAL_ROOT\t%s\n' "$STATE_LOCAL_ROOT"
        printf 'DESTINATION\t%s\n' "$STATE_DESTINATION"
        printf 'STARTED\t%s\n' "$STATE_STARTED"
        printf 'COMPLETED\t%s\n' "$STATE_COMPLETED"
        printf 'RSYNC_EXIT\t%s\n' "$STATE_RSYNC_EXIT"
        printf 'VERIFY_MODE\t%s\n' "$STATE_VERIFY_MODE"
        printf 'VERIFY\t%s\n' "$STATE_VERIFY"
        printf 'STATUS\t%s\n' "$STATE_STATUS"
        printf 'FILES\t%s\n' "$STATE_FILES"
        printf 'FOLDERS\t%s\n' "$STATE_FOLDERS"
        printf 'BYTES\t%s\n' "$STATE_BYTES"
        printf 'MANIFEST_FILE\t%s\n' "$STATE_MANIFEST_FILE"
        printf 'LOG_FILE\t%s\n' "$STATE_LOG_FILE"
        printf 'ARCHIVED_AT\t%s\n' "$STATE_ARCHIVED_AT"
        printf 'DELETED_AT\t%s\n' "$STATE_DELETED_AT"
    } > "$state_file"
}

load_transfer_state() {
    local state_file="$1"
    [[ -f "$state_file" ]] || return 1

    STATE_TRANSFER_ID=""
    STATE_SOURCE_ROOT=""
    STATE_LOCAL_ROOT=""
    STATE_DESTINATION=""
    STATE_STARTED=""
    STATE_COMPLETED=""
    STATE_RSYNC_EXIT=""
    STATE_VERIFY_MODE=""
    STATE_VERIFY=""
    STATE_STATUS=""
    STATE_FILES="0"
    STATE_FOLDERS="0"
    STATE_BYTES="0"
    STATE_MANIFEST_FILE=""
    STATE_LOG_FILE=""
    STATE_ARCHIVED_AT=""
    STATE_DELETED_AT=""

    local key value
    while IFS=$'\t' read -r key value; do
        case "$key" in
            TRANSFER_ID) STATE_TRANSFER_ID="$value" ;;
            SOURCE_ROOT) STATE_SOURCE_ROOT="$value" ;;
            LOCAL_ROOT) STATE_LOCAL_ROOT="$value" ;;
            DESTINATION) STATE_DESTINATION="$value" ;;
            STARTED) STATE_STARTED="$value" ;;
            COMPLETED) STATE_COMPLETED="$value" ;;
            RSYNC_EXIT) STATE_RSYNC_EXIT="$value" ;;
            VERIFY_MODE) STATE_VERIFY_MODE="$value" ;;
            VERIFY) STATE_VERIFY="$value" ;;
            STATUS) STATE_STATUS="$value" ;;
            FILES) STATE_FILES="$value" ;;
            FOLDERS) STATE_FOLDERS="$value" ;;
            BYTES) STATE_BYTES="$value" ;;
            MANIFEST_FILE) STATE_MANIFEST_FILE="$value" ;;
            LOG_FILE) STATE_LOG_FILE="$value" ;;
            ARCHIVED_AT) STATE_ARCHIVED_AT="$value" ;;
            DELETED_AT) STATE_DELETED_AT="$value" ;;
        esac
    done < "$state_file"

    LAST_STATE_FILE="$state_file"
    return 0
}

load_last_transfer_state() {
    [[ -s "$LAST_TRANSFER_POINTER" ]] || return 1
    local state_file
    IFS= read -r state_file < "$LAST_TRANSFER_POINTER"
    [[ -n "$state_file" ]] || return 1
    load_transfer_state "$state_file"
}

state_local_folders() {
    local -n output_array="$1"
    output_array=()

    [[ -f "$STATE_MANIFEST_FILE" ]] || return 1
    [[ -d "$STATE_LOCAL_ROOT" ]] || return 1

    local folder_name folder_path
    while IFS= read -r folder_name; do
        [[ -z "$folder_name" ]] && continue
        folder_path="${STATE_LOCAL_ROOT}/${folder_name}"
        [[ -d "$folder_path" ]] || return 1
        output_array+=("$folder_path")
    done < "$STATE_MANIFEST_FILE"

    [[ ${#output_array[@]} -gt 0 ]]
}

verify_folder_set() {
    local destination="$1"
    local mode="$2"
    local log_file="$3"
    shift 3
    local folders=("$@")
    local verify_file
    local rc
    local pending
    local -a verify_args=(-ans --itemize-changes --out-format='%i|%n%L')

    if [[ "$mode" == "deep" ]]; then
        verify_args+=(-c)
    fi

    verify_file=$(mktemp "${VAR_DIR}/.verify.XXXXXX") || return 1

    echo
    if [[ "$mode" == "deep" ]]; then
        echo "Deep checksum verification..."
        log_line "$log_file" "Deep checksum verification started"
    else
        echo "Standard verification (size/timestamp)..."
        log_line "$log_file" "Standard verification started"
    fi

    rsync "${verify_args[@]}" -- "${folders[@]}" "${destination%/}/" > "$verify_file" 2>> "$log_file"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
        echo -e "  ${RED}${BOLD}[FAILED]${NC} Verification rsync returned exit code $rc."
        log_line "$log_file" "Verification failed: rsync exit code $rc"
        rm -f -- "$verify_file"
        return 1
    fi

    pending=$(grep -c . "$verify_file" 2>/dev/null || true)

    if [[ "$pending" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}[Verified]${NC} No pending differences found."
        log_line "$log_file" "Verification PASS mode=$mode pending=0"
        rm -f -- "$verify_file"
        return 0
    fi

    echo -e "  ${RED}${BOLD}[FAILED]${NC} $pending item(s) still differ from the NAS."
    echo
    echo "First differences:"
    sed -n '1,20p' "$verify_file" | sed 's/^/  /'
    if [[ "$pending" -gt 20 ]]; then
        echo "  ..."
    fi
    cat "$verify_file" >> "$log_file"
    log_line "$log_file" "Verification FAIL mode=$mode pending=$pending"
    rm -f -- "$verify_file"
    return 1
}

verify_transfer_state_file() {
    local state_file="$1"

    if ! load_transfer_state "$state_file"; then
        echo -e "${RED}ERROR:${NC} Transfer state could not be loaded."
        return 1
    fi

    if [[ "$STATE_STATUS" == "DELETED" ]]; then
        echo -e "${YELLOW}This transfer has already been deleted from local transferred storage.${NC}"
        echo "The transfer log and state record remain available for audit."
        return 1
    fi

    local -a folders=()
    if ! state_local_folders folders; then
        echo -e "${RED}ERROR:${NC} The recorded local transfer folders cannot all be found."
        echo "No verification was attempted."
        return 1
    fi

    echo -e "${BOLD}VERIFY TRANSFER${NC}"
    echo
    echo "Transfer ID : $STATE_TRANSFER_ID"
    echo "Destination : $STATE_DESTINATION"
    echo "Local root  : $STATE_LOCAL_ROOT"
    echo "Files       : $STATE_FILES"
    echo "Folders     : $STATE_FOLDERS"
    echo "Status      : $STATE_STATUS"
    echo
    echo "Verification mode:"
    echo
    echo "  1) Standard - size / timestamp comparison"
    echo "  2) Deep     - checksum comparison"
    echo "  Enter) Cancel"
    echo

    local choice mode previous_status
    read -r -p "Selection: " choice
    case "$choice" in
        1) mode="standard" ;;
        2) mode="deep" ;;
        "") return 2 ;;
        *) echo "Invalid selection."; return 2 ;;
    esac

    previous_status="$STATE_STATUS"

    if verify_folder_set "$STATE_DESTINATION" "$mode" "$STATE_LOG_FILE" "${folders[@]}"; then
        STATE_VERIFY_MODE="$mode"
        STATE_VERIFY="PASS"
        case "$previous_status" in
            ARCHIVED|ARCHIVED_UNVERIFIED) STATE_STATUS="ARCHIVED" ;;
            *) STATE_STATUS="VERIFIED" ;;
        esac
        write_transfer_state "$state_file"
        echo -e "${GREEN}${BOLD}[Verified] Transfer $STATE_TRANSFER_ID matches the NAS destination.${NC}"
        return 0
    fi

    STATE_VERIFY_MODE="$mode"
    STATE_VERIFY="FAIL"
    case "$previous_status" in
        ARCHIVED|ARCHIVED_UNVERIFIED) STATE_STATUS="ARCHIVED_UNVERIFIED" ;;
        *) STATE_STATUS="UNVERIFIED" ;;
    esac
    write_transfer_state "$state_file"
    echo -e "${RED}${BOLD}[Attention] Transfer verification did not pass.${NC}"
    echo "Archive/deletion actions are blocked until verification passes."
    return 1
}

verify_last_transfer() {
    header

    if [[ ! -s "$LAST_TRANSFER_POINTER" ]]; then
        echo -e "${YELLOW}No recorded transfer is available to verify.${NC}"
        pause
        return
    fi

    local state_file
    IFS= read -r state_file < "$LAST_TRANSFER_POINTER"

    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        echo -e "${YELLOW}The last-transfer state pointer is not valid.${NC}"
        pause
        return
    fi

    verify_transfer_state_file "$state_file"
    pause
}

rsync_to_nas() {
    header

    if ! get_config; then
        echo -e "${RED}Configuration error.${NC}"
        pause
        return
    fi

    mkdir -p "$LOG_DIR" "$TRANSFER_STATE_DIR"

    echo -e "${CYAN}RSYNC TO NAS${NC}"
    echo
    echo "Source:"
    echo "  $SOURCE"
    echo

    if ! choose_destination; then
        pause
        return
    fi

    echo
    echo "Selected destination:"
    echo "  $SELECTED_DESTINATION"
    echo

    shopt -s nullglob
    local folders=( "$SOURCE"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-00\ -\ * )
    shopt -u nullglob

    if [[ ${#folders[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No monthly archive folders found.${NC}"
        pause
        return
    fi

    local total_files=0 total_bytes=0 folder
    for folder in "${folders[@]}"; do
        total_files=$(( total_files + $(count_tree_files "$folder") ))
        total_bytes=$(( total_bytes + $(count_tree_bytes "$folder") ))
    done

    echo "Monthly folders:"
    echo
    for folder in "${folders[@]}"; do
        printf '  %s\n' "$(basename "$folder")"
    done
    echo
    echo "Transfer summary:"
    echo "  Folders : ${#folders[@]}"
    echo "  Files   : $total_files"
    echo "  Size    : $(human_bytes "$total_bytes")"
    echo
    echo "Destination:"
    echo "  $SELECTED_DESTINATION"
    echo

    read -r -p "Proceed with rsync? [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo
            echo "Cancelled."
            pause
            return
            ;;
    esac

    local transfer_id started completed log_file state_file manifest_file rc
    transfer_id=$(date '+%Y%m%d-%H%M%S')
    started=$(date --iso-8601=seconds)
    log_file="${LOG_DIR}/transfer-${transfer_id}.log"
    state_file="${TRANSFER_STATE_DIR}/${transfer_id}.state"
    manifest_file="${TRANSFER_STATE_DIR}/${transfer_id}.manifest"

    : > "$log_file"
    : > "$manifest_file"
    for folder in "${folders[@]}"; do
        basename "$folder" >> "$manifest_file"
    done

    log_line "$log_file" "Transfer started id=$transfer_id"
    log_line "$log_file" "Source=$SOURCE"
    log_line "$log_file" "Destination=$SELECTED_DESTINATION"
    log_line "$log_file" "Folders=${#folders[@]} Files=$total_files Bytes=$total_bytes"

    echo
    echo "Starting rsync..."
    echo "Transfer log: ${log_file#${SCRIPT_DIR}/}"
    echo

    rsync -avhs --progress -- "${folders[@]}" "${SELECTED_DESTINATION%/}/" 2>&1 | tee -a "$log_file"
    rc=${PIPESTATUS[0]}
    completed=$(date --iso-8601=seconds)

    STATE_TRANSFER_ID="$transfer_id"
    STATE_SOURCE_ROOT="$SOURCE"
    STATE_LOCAL_ROOT="$SOURCE"
    STATE_DESTINATION="$SELECTED_DESTINATION"
    STATE_STARTED="$started"
    STATE_COMPLETED="$completed"
    STATE_RSYNC_EXIT="$rc"
    STATE_VERIFY_MODE=""
    STATE_VERIFY="NOT_RUN"
    STATE_STATUS="TRANSFER_FAILED"
    STATE_FILES="$total_files"
    STATE_FOLDERS="${#folders[@]}"
    STATE_BYTES="$total_bytes"
    STATE_MANIFEST_FILE="$manifest_file"
    STATE_LOG_FILE="$log_file"
    STATE_ARCHIVED_AT=""
    STATE_DELETED_AT=""

    if [[ "$rc" -ne 0 ]]; then
        write_transfer_state "$state_file"
        printf '%s\n' "$state_file" > "$LAST_TRANSFER_POINTER"
        log_line "$log_file" "Transfer FAILED rsync_exit=$rc"
        echo
        echo -e "${RED}Rsync returned exit code $rc.${NC}"
        echo "The transfer was recorded but is not eligible for post-transfer cleanup."
        pause
        return
    fi

    STATE_STATUS="TRANSFERRED_UNVERIFIED"
    write_transfer_state "$state_file"
    printf '%s\n' "$state_file" > "$LAST_TRANSFER_POINTER"
    log_line "$log_file" "Transfer completed rsync_exit=0"

    echo
    echo -e "${GREEN}${BOLD}[Complete] Rsync transfer completed successfully.${NC}"

    if verify_folder_set "$SELECTED_DESTINATION" "standard" "$log_file" "${folders[@]}"; then
        STATE_VERIFY_MODE="standard"
        STATE_VERIFY="PASS"
        STATE_STATUS="VERIFIED"
        write_transfer_state "$state_file"
        echo -e "${GREEN}${BOLD}[Verified] $total_files files across ${#folders[@]} folders match the NAS destination.${NC}"

        echo
        read -r -p "Run deep checksum verification now? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES)
                if verify_folder_set "$SELECTED_DESTINATION" "deep" "$log_file" "${folders[@]}"; then
                    STATE_VERIFY_MODE="deep"
                    STATE_VERIFY="PASS"
                    STATE_STATUS="VERIFIED"
                    write_transfer_state "$state_file"
                    echo -e "${GREEN}${BOLD}[Verified] Deep checksum verification passed.${NC}"
                else
                    STATE_VERIFY_MODE="deep"
                    STATE_VERIFY="FAIL"
                    STATE_STATUS="UNVERIFIED"
                    write_transfer_state "$state_file"
                    echo -e "${RED}${BOLD}[Attention] Deep checksum verification failed.${NC}"
                fi
                ;;
        esac
    else
        STATE_VERIFY_MODE="standard"
        STATE_VERIFY="FAIL"
        STATE_STATUS="UNVERIFIED"
        write_transfer_state "$state_file"
        echo -e "${RED}${BOLD}[Attention] Standard post-transfer verification failed.${NC}"
    fi

    log_line "$log_file" "Final status=${STATE_STATUS} verify=${STATE_VERIFY} mode=${STATE_VERIFY_MODE}"

    echo
    echo "State record: ${state_file#${SCRIPT_DIR}/}"
    echo "Transfer log: ${log_file#${SCRIPT_DIR}/}"

    if [[ "$STATE_STATUS" == "VERIFIED" ]]; then
        echo
        echo -e "${GREEN}${BOLD}Next: option 6 can move this verified batch into transferred/.${NC}"
    else
        echo
        echo -e "${YELLOW}Post-transfer archive is blocked until option 5 verification passes.${NC}"
    fi

    pause
}

archive_transfer_state_file() {
    local state_file="$1"

    if ! load_transfer_state "$state_file"; then
        echo -e "${RED}ERROR:${NC} Transfer state could not be loaded."
        return 1
    fi

    if [[ "$STATE_STATUS" != "VERIFIED" || "$STATE_VERIFY" != "PASS" ]]; then
        echo -e "${RED}${BOLD}[Blocked]${NC} This transfer is not in VERIFIED state."
        echo
        echo "Status       : $STATE_STATUS"
        echo "Verification : $STATE_VERIFY"
        echo
        echo "Verify this batch successfully before archiving local files."
        return 1
    fi

    if [[ "$STATE_LOCAL_ROOT" != "$STATE_SOURCE_ROOT" ]]; then
        echo -e "${RED}${BOLD}[Blocked]${NC} The verified transfer is not located in its recorded import source."
        return 1
    fi

    local batch_dir="${TRANSFERRED_DIR}/${STATE_TRANSFER_ID}"
    local -a folders=()
    local folder_name source_path target_path
    local missing=0 collisions=0

    [[ -f "$STATE_MANIFEST_FILE" ]] || {
        echo -e "${RED}ERROR:${NC} Transfer manifest is missing."
        return 1
    }

    while IFS= read -r folder_name; do
        [[ -z "$folder_name" ]] && continue
        source_path="${STATE_LOCAL_ROOT}/${folder_name}"
        target_path="${batch_dir}/${folder_name}"
        if [[ ! -d "$source_path" ]]; then
            echo -e "${RED}MISSING:${NC} $source_path"
            ((missing++))
        fi
        if [[ -e "$target_path" ]]; then
            echo -e "${RED}COLLISION:${NC} $target_path"
            ((collisions++))
        fi
        folders+=("$source_path")
    done < "$STATE_MANIFEST_FILE"

    if [[ "$missing" -gt 0 || "$collisions" -gt 0 ]]; then
        echo
        echo -e "${RED}${BOLD}[Blocked]${NC} No files were moved. Resolve the issues above first."
        return 1
    fi

    # Re-check immediately before local retirement. This catches files that
    # were added/changed in the recorded folders after the original transfer.
    echo
    echo "Re-checking this batch against the NAS before archival..."
    if ! verify_folder_set "$STATE_DESTINATION" "standard" "$STATE_LOG_FILE" "${folders[@]}"; then
        STATE_VERIFY_MODE="standard"
        STATE_VERIFY="FAIL"
        STATE_STATUS="UNVERIFIED"
        write_transfer_state "$state_file"
        echo -e "${RED}${BOLD}[Blocked]${NC} Pre-archive verification failed. No local files were moved."
        return 1
    fi

    STATE_VERIFY_MODE="standard"
    STATE_VERIFY="PASS"
    STATE_STATUS="VERIFIED"
    write_transfer_state "$state_file"

    echo
    echo -e "${BOLD}MOVE VERIFIED TRANSFER TO transferred/${NC}"
    echo
    echo "Transfer ID : $STATE_TRANSFER_ID"
    echo "Destination : $STATE_DESTINATION"
    echo "Verified    : $STATE_VERIFY_MODE"
    echo "Files       : $STATE_FILES"
    echo "Folders     : $STATE_FOLDERS"
    echo "Size        : $(human_bytes "$STATE_BYTES")"
    echo
    echo "From:"
    echo "  $STATE_LOCAL_ROOT"
    echo
    echo "To:"
    echo "  $batch_dir"
    echo
    echo "Only folders recorded in the verified transfer manifest will be moved."
    echo "Anything outside those recorded folders is left untouched."
    echo
    echo "Folders:"
    local shown=0
    for source_path in "${folders[@]}"; do
        printf '  %s\n' "$(basename "$source_path")"
        ((shown++))
        if [[ "$shown" -eq 10 && ${#folders[@]} -gt 10 ]]; then
            echo "  ... (${#folders[@]} total)"
            break
        fi
    done
    echo
    read -r -p "Move this verified batch to transferred/? [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo "Cancelled. No files were moved."
            return 2
            ;;
    esac

    mkdir -p -- "$batch_dir"
    local moved=0 total=${#folders[@]} i
    echo
    for i in "${!folders[@]}"; do
        if mv -- "${folders[$i]}" "$batch_dir/"; then
            ((moved++))
        else
            clear_progress
            echo -e "${RED}ERROR:${NC} Failed to move $(basename "${folders[$i]}")"
            break
        fi
        show_progress "$((i + 1))" "$total" "Archiving"
    done
    clear_progress
    echo

    if [[ "$moved" -ne "$total" ]]; then
        echo -e "${RED}${BOLD}[Attention]${NC} Only $moved/$total folders were moved."
        echo "State remains VERIFIED so the batch is not eligible for deletion."
        log_line "$STATE_LOG_FILE" "Archive move PARTIAL moved=$moved total=$total"
        return 1
    fi

    STATE_LOCAL_ROOT="$batch_dir"
    STATE_STATUS="ARCHIVED"
    STATE_ARCHIVED_AT=$(date --iso-8601=seconds)
    write_transfer_state "$state_file"
    log_line "$STATE_LOG_FILE" "Archived locally path=$batch_dir"

    echo
    echo -e "${GREEN}${BOLD}[Complete] Verified transfer moved to transferred/${STATE_TRANSFER_ID}/${NC}"
    echo "The import/source directory was not deleted or cleared."
    return 0
}

move_verified_transfer() {
    header

    if ! get_config; then
        echo -e "${RED}Configuration error.${NC}"
        pause
        return
    fi

    if [[ ! -s "$LAST_TRANSFER_POINTER" ]]; then
        echo -e "${YELLOW}No recorded transfer is available.${NC}"
        pause
        return
    fi

    local state_file
    IFS= read -r state_file < "$LAST_TRANSFER_POINTER"
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        echo -e "${YELLOW}The last-transfer state pointer is not valid.${NC}"
        pause
        return
    fi

    archive_transfer_state_file "$state_file"
    pause
}

safe_transferred_batch() {
    local batch="$1"
    local expected_root resolved_batch resolved_source resolved_default resolved_state_source

    [[ -d "$batch" ]] || return 1
    [[ "$batch" != "$TRANSFERRED_DIR" ]] || return 1
    [[ "$batch" == "$TRANSFERRED_DIR/"* ]] || return 1

    if command -v realpath >/dev/null 2>&1; then
        expected_root=$(realpath -m -- "$TRANSFERRED_DIR") || return 1
        resolved_batch=$(realpath -m -- "$batch") || return 1
        resolved_source=$(realpath -m -- "$SOURCE") || return 1
        resolved_default=$(realpath -m -- "$DEFAULT_SOURCE") || return 1

        [[ "$resolved_batch" == "$expected_root/"* ]] || return 1

        # Never delete the configured import source, the built-in cloud-IN,
        # or anything beneath either path even if a user configures an
        # unusual source location.
        [[ "$resolved_batch" != "$resolved_source" ]] || return 1
        [[ "$resolved_batch" != "$resolved_source/"* ]] || return 1
        [[ "$resolved_batch" != "$resolved_default" ]] || return 1
        [[ "$resolved_batch" != "$resolved_default/"* ]] || return 1

        # Also honour the source path recorded in the selected transfer state.
        if [[ -n "${STATE_SOURCE_ROOT:-}" ]]; then
            resolved_state_source=$(realpath -m -- "$STATE_SOURCE_ROOT") || return 1
            [[ "$resolved_batch" != "$resolved_state_source" ]] || return 1
            [[ "$resolved_batch" != "$resolved_state_source/"* ]] || return 1
        fi
    fi

    return 0
}

page_text_file() {
    local file="$1"
    [[ -f "$file" ]] || {
        echo -e "${YELLOW}File not found: $file${NC}"
        return 1
    }

    if command -v less >/dev/null 2>&1; then
        less -- "$file"
    else
        cat -- "$file"
    fi
}

status_badge() {
    local status="$1"
    case "$status" in
        ARCHIVED) printf '%b' "${GREEN}${BOLD}${status}${NC}" ;;
        VERIFIED) printf '%b' "${GREEN}${status}${NC}" ;;
        DELETED) printf '%b' "${YELLOW}${status}${NC}" ;;
        *FAIL*|UNVERIFIED|ARCHIVED_UNVERIFIED) printf '%b' "${RED}${status}${NC}" ;;
        *) printf '%s' "$status" ;;
    esac
}

delete_archived_state_file() {
    local state_file="$1"

    if ! load_transfer_state "$state_file"; then
        echo -e "${RED}ERROR:${NC} Transfer state could not be loaded."
        return 1
    fi

    if [[ "$STATE_STATUS" != "ARCHIVED" || "$STATE_VERIFY" != "PASS" ]]; then
        echo -e "${RED}${BOLD}[Blocked]${NC} This batch is not an eligible verified ARCHIVED batch."
        echo "Status       : $STATE_STATUS"
        echo "Verification : $STATE_VERIFY"
        return 1
    fi

    local batch="$STATE_LOCAL_ROOT"
    if ! safe_transferred_batch "$batch"; then
        echo -e "${RED}${BOLD}[Safety block]${NC} Refusing unexpected archived path:"
        echo "  $batch"
        return 1
    fi

    local files bytes
    files=$(count_tree_files "$batch")
    bytes=$(count_tree_bytes "$batch")

    echo -e "${RED}${BOLD}DELETE ARCHIVED TRANSFER BATCH${NC}"
    echo
    echo -e "${RED}${BOLD}WARNING: This permanently deletes the selected local archived copy.${NC}"
    echo
    echo "Transfer ID : $STATE_TRANSFER_ID"
    echo "Destination : $STATE_DESTINATION"
    echo "Batch path  : $batch"
    echo "Files       : $files"
    echo "Size        : $(human_bytes "$bytes")"
    echo
    echo -e "${GREEN}${BOLD}[Safety] The import/source directory is never a deletion target.${NC}"
    echo "Only this state-confirmed ARCHIVED batch beneath transferred/ can be removed."
    echo
    echo "Type DELETE exactly to permanently remove this batch."
    echo "Any other input cancels."
    echo

    local confirmation
    read -r -p "> " confirmation
    if [[ "$confirmation" != "DELETE" ]]; then
        echo
        echo "Cancelled. No files were deleted."
        return 2
    fi

    # Final re-load and safety check immediately before deletion.
    if ! load_transfer_state "$state_file" || \
       [[ "$STATE_STATUS" != "ARCHIVED" || "$STATE_VERIFY" != "PASS" ]] || \
       ! safe_transferred_batch "$STATE_LOCAL_ROOT"; then
        echo -e "${RED}${BOLD}[Safety block]${NC} State/path changed before deletion. Nothing was deleted."
        return 1
    fi

    batch="$STATE_LOCAL_ROOT"
    if rm -rf -- "$batch"; then
        STATE_STATUS="DELETED"
        STATE_DELETED_AT=$(date --iso-8601=seconds)
        STATE_LOCAL_ROOT=""
        write_transfer_state "$state_file"
        [[ -n "$STATE_LOG_FILE" ]] && log_line "$STATE_LOG_FILE" "Local transferred batch deleted after explicit DELETE confirmation"
        echo
        echo -e "${GREEN}${BOLD}[Complete] Transfer batch $STATE_TRANSFER_ID deleted from transferred/.${NC}"
        echo "Transfer log, manifest and state record have been retained."
        return 0
    fi

    echo -e "${RED}${BOLD}[FAILED]${NC} Could not delete the selected batch."
    return 1
}

delete_transferred_files() {
    header

    if ! get_config; then
        echo -e "${RED}Configuration error.${NC}"
        pause
        return
    fi

    mkdir -p "$TRANSFERRED_DIR" "$TRANSFER_STATE_DIR"

    local -a eligible_states=()
    local state_file

    shopt -s nullglob
    local -a all_states=( "$TRANSFER_STATE_DIR"/*.state )
    shopt -u nullglob

    while IFS= read -r state_file; do
        [[ -z "$state_file" ]] && continue
        if load_transfer_state "$state_file" && \
           [[ "$STATE_STATUS" == "ARCHIVED" && "$STATE_VERIFY" == "PASS" ]] && \
           safe_transferred_batch "$STATE_LOCAL_ROOT"; then
            eligible_states+=("$state_file")
        fi
    done < <(printf '%s\n' "${all_states[@]}" | sort -r)

    if [[ ${#eligible_states[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No verified archived transfer batches are eligible for deletion.${NC}"
        echo
        echo "Cloud-to-NAS will never delete files directly from cloud-IN or the configured import source."
        pause
        return
    fi

    echo -e "${RED}${BOLD}DELETE TRANSFERRED FILES - SELECT BATCH${NC}"
    echo
    echo "Select one archived batch to inspect and, if desired, permanently delete."
    echo

    local i
    for i in "${!eligible_states[@]}"; do
        load_transfer_state "${eligible_states[$i]}"
        printf '  %d) %s  %s files  %s\n' \
            "$((i + 1))" "$STATE_TRANSFER_ID" "$STATE_FILES" "$(human_bytes "$STATE_BYTES")"
        printf '     %s\n' "$STATE_DESTINATION"
    done

    echo
    echo "  Enter) Cancel"
    echo

    local choice
    read -r -p "Select batch [1-${#eligible_states[@]}]: " choice
    [[ -z "$choice" ]] && return

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#eligible_states[@]} )); then
        echo "Invalid selection."
        pause
        return
    fi

    echo
    delete_archived_state_file "${eligible_states[$((choice - 1))]}"
    pause
}

batch_manager() {
    if ! get_config; then
        header
        echo -e "${RED}Configuration error.${NC}"
        pause
        return
    fi

    mkdir -p "$TRANSFER_STATE_DIR" "$TRANSFERRED_DIR"

    while true; do
        header
        echo -e "${BOLD}TRANSFER BATCH MANAGER${NC}"
        echo

        shopt -s nullglob
        local -a states=( "$TRANSFER_STATE_DIR"/*.state )
        shopt -u nullglob

        if [[ ${#states[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No transfer batches have been recorded yet.${NC}"
            pause
            return
        fi

        local -a sorted_states=()
        local state_file
        while IFS= read -r state_file; do
            [[ -n "$state_file" ]] && sorted_states+=("$state_file")
        done < <(printf '%s\n' "${states[@]}" | sort -r)

        echo "Recorded transfer batches (newest first):"
        echo

        local i
        for i in "${!sorted_states[@]}"; do
            if ! load_transfer_state "${sorted_states[$i]}"; then
                continue
            fi
            printf '  %d) %s  ' "$((i + 1))" "$STATE_TRANSFER_ID"
            status_badge "$STATE_STATUS"
            printf '  %s files  %s\n' "$STATE_FILES" "$(human_bytes "$STATE_BYTES")"
            printf '     -> %s\n' "$STATE_DESTINATION"
        done

        echo
        echo "  Enter) Return to main menu"
        echo

        local choice
        read -r -p "Select batch [1-${#sorted_states[@]}]: " choice
        [[ -z "$choice" ]] && return

        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#sorted_states[@]} )); then
            echo "Invalid selection."
            sleep 1
            continue
        fi

        state_file="${sorted_states[$((choice - 1))]}"

        while true; do
            header
            if ! load_transfer_state "$state_file"; then
                echo -e "${RED}Unable to load selected batch state.${NC}"
                pause
                break
            fi

            echo -e "${BOLD}TRANSFER BATCH${NC}"
            echo
            echo "Transfer ID  : $STATE_TRANSFER_ID"
            echo -n "Status       : "
            status_badge "$STATE_STATUS"
            echo
            echo "Verification : $STATE_VERIFY${STATE_VERIFY_MODE:+ ($STATE_VERIFY_MODE)}"
            echo "Destination  : $STATE_DESTINATION"
            echo "Source       : $STATE_SOURCE_ROOT"
            echo "Local root   : ${STATE_LOCAL_ROOT:-<local copy deleted>}"
            echo "Started      : $STATE_STARTED"
            echo "Completed    : $STATE_COMPLETED"
            echo "Archived     : ${STATE_ARCHIVED_AT:-<not archived>}"
            echo "Deleted      : ${STATE_DELETED_AT:-<not deleted>}"
            echo "Files        : $STATE_FILES"
            echo "Folders      : $STATE_FOLDERS"
            echo "Size         : $(human_bytes "$STATE_BYTES")"
            echo
            echo "Actions:"
            echo

            case "$STATE_STATUS" in
                VERIFIED)
                    echo "  a) Archive this verified batch to transferred/"
                    echo "  v) Verify this batch again"
                    ;;
                ARCHIVED)
                    echo "  v) Verify this archived batch again"
                    echo -e "  ${RED}d) DELETE this archived batch${NC}"
                    ;;
                ARCHIVED_UNVERIFIED)
                    echo "  v) Re-verify this archived batch"
                    echo -e "  ${RED}   Deletion blocked until verification passes${NC}"
                    ;;
                DELETED)
                    echo "  Local batch has already been deleted; audit records remain."
                    ;;
                *)
                    if [[ -n "$STATE_LOCAL_ROOT" && -d "$STATE_LOCAL_ROOT" ]]; then
                        echo "  v) Verify this batch"
                    fi
                    ;;
            esac

            echo "  m) View manifest"
            echo "  l) View transfer log"
            echo "  Enter) Back to batch list"
            echo

            read -r -p "Selection: " choice
            case "$choice" in
                a|A)
                    if [[ "$STATE_STATUS" != "VERIFIED" ]]; then
                        echo "This batch is not eligible for archival."
                        pause
                    else
                        archive_transfer_state_file "$state_file"
                        pause
                    fi
                    ;;
                v|V)
                    if [[ "$STATE_STATUS" == "DELETED" ]]; then
                        echo "The local copy has been deleted, so it cannot be re-verified from local storage."
                        pause
                    else
                        verify_transfer_state_file "$state_file"
                        pause
                    fi
                    ;;
                d|D)
                    if [[ "$STATE_STATUS" != "ARCHIVED" ]]; then
                        echo "Only a verified ARCHIVED batch can be deleted."
                        pause
                    else
                        delete_archived_state_file "$state_file"
                        pause
                    fi
                    ;;
                m|M)
                    page_text_file "$STATE_MANIFEST_FILE"
                    ;;
                l|L)
                    page_text_file "$STATE_LOG_FILE"
                    ;;
                "")
                    break
                    ;;
                *)
                    echo "Invalid selection."
                    sleep 1
                    ;;
            esac
        done
    done
}

show_import_folder() {
    header

    if ! get_config; then
        echo -e "${RED}Configuration is incomplete.${NC}"
        pause
        return
    fi

    mkdir -p "$TRANSFERRED_DIR"

    echo -e "${BOLD}IMPORT STATUS${NC}"
    echo
    echo "Scanning import tree..."

    local import_files=0 import_bytes=0 import_depth=0 top_dirs=0
    local path rel size slashes depth first_component
    declare -A top_dir_counts=()

    while IFS= read -r -d '' path; do
        ((import_files++))

        size=$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        ((import_bytes += size))

        rel="${path#"$SOURCE"/}"
        slashes="${rel//[^\/]/}"
        depth=${#slashes}
        (( depth > import_depth )) && import_depth=$depth

        if [[ "$rel" == */* ]]; then
            first_component="${rel%%/*}"
            top_dir_counts["$first_component"]=$(( ${top_dir_counts["$first_component"]:-0} + 1 ))
        fi

        show_activity "$import_files" "Scanning import"
    done < <(find_import_files "$SOURCE")
    clear_progress
    printf '  [Complete] Import scan: %d file(s)\n' "$import_files"

    top_dirs=$(find "$SOURCE" -mindepth 1 -maxdepth 1 -type d ! -name '__MACOSX' 2>/dev/null | wc -l)

    echo
    echo "Scanning transferred batches..."

    local transferred_files=0 transferred_bytes=0 transferred_batches=0
    while IFS= read -r -d '' path; do
        ((transferred_files++))
        size=$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        ((transferred_bytes += size))
        show_activity "$transferred_files" "Scanning transferred"
    done < <(find "$TRANSFERRED_DIR" -type f ! -name '.gitkeep' -print0 2>/dev/null)
    clear_progress
    printf '  [Complete] Transferred scan: %d file(s)\n' "$transferred_files"
    transferred_batches=$(find "$TRANSFERRED_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    echo
    echo "------------------------------------------------------------"
    echo
    echo "cloud-IN / configured source"
    echo "  Path              : $SOURCE"
    echo "  Files (recursive) : $import_files"
    echo "  Top-level folders : $top_dirs"
    echo "  Maximum depth     : $import_depth"
    echo "  Size              : $(human_bytes "$import_bytes")"
    echo

    echo "Preview - first 20 top-level entries:"
    local preview_count=0 entry_type entry_name entry_path entry_files
    while IFS=$'\t' read -r entry_type entry_name; do
        [[ -z "$entry_name" ]] && continue
        [[ "$entry_name" == ".gitkeep" || "$entry_name" == ".DS_Store" || "$entry_name" == "__MACOSX" ]] && continue
        entry_path="$SOURCE/$entry_name"
        case "$entry_type" in
            d)
                entry_files="${top_dir_counts[$entry_name]:-0}"
                printf '  [DIR ] %s (%d files)\n' "$entry_name" "$entry_files"
                ;;
            f) printf '  [FILE] %s\n' "$entry_name" ;;
            *) printf '  [OTHER] %s\n' "$entry_name" ;;
        esac
        ((preview_count++))
        [[ "$preview_count" -ge 20 ]] && break
    done < <(find "$SOURCE" -mindepth 1 -maxdepth 1 -printf '%y\t%f\n' 2>/dev/null | sort -k2)

    [[ "$preview_count" -eq 0 ]] && echo -e "  ${GREEN}[Empty]${NC} Ready for cloud photo files."

    if (( import_depth > 0 )); then
        echo
        echo -e "${GREEN}${BOLD}[Recursive] Nested cloud-export content detected and will be processed.${NC}"
    fi

    echo
    echo "transferred"
    echo "  Path    : $TRANSFERRED_DIR"
    echo "  Batches : $transferred_batches"
    echo "  Files   : $transferred_files"
    echo "  Size    : $(human_bytes "$transferred_bytes")"

    echo
    echo "Last transfer"
    if load_last_transfer_state; then
        echo "  ID           : $STATE_TRANSFER_ID"
        echo "  Destination  : $STATE_DESTINATION"
        echo "  Status       : $STATE_STATUS"
        echo "  Verification : $STATE_VERIFY${STATE_VERIFY_MODE:+ ($STATE_VERIFY_MODE)}"
        echo "  Completed    : $STATE_COMPLETED"
    else
        echo "  No transfer state recorded yet."
    fi

    pause
}

show_configuration() {
    header
    if ! get_config; then
        echo -e "${RED}Configuration is incomplete.${NC}"
        pause
        return
    fi
    show_paths
    pause
}

main_menu() {
    while true; do
        header

        if get_config >/dev/null 2>&1; then
            echo "Source:"
            echo "  $SOURCE"
        else
            echo -e "${YELLOW}Paths are not configured.${NC}"
        fi

        echo
        echo -e "${BOLD}Stage 1 - Prepare${NC}"
        echo
        echo "  1) Rename - dry run"
        echo "  2) Rename"
        echo "  3) Folder Move - month per year"
        echo
        echo -e "${BOLD}Stage 2 - Transfer${NC}"
        echo
        echo "  4) Rsync to destination NAS"
        echo "  5) Verify last transfer"
        echo
        echo -e "${BOLD}Stage 3 - Post-transfer${NC}"
        echo
        echo "  6) Move verified transfer to transferred/"
        echo -e "  ${RED}7) DELETE selected archived batch${NC}"
        echo "  b) Batch manager"
        echo
        echo -e "${BOLD}Configuration${NC}"
        echo
        echo "  c) Show configured paths"
        echo "  r) Reconfigure paths"
        echo "  t) Test NAS destination paths"
        echo
        echo -e "${BOLD}Other${NC}"
        echo
        echo "  s) Show import / transfer status"
        echo "  l) View transfer logs"
        echo
        echo "  0) Exit"
        echo

        read -r -p "Selection: " choice

        case "$choice" in
            1) rename_files 1 ;;
            2) rename_files 0 ;;
            3) folder_move ;;
            4) rsync_to_nas ;;
            5) verify_last_transfer ;;
            6) move_verified_transfer ;;
            7) delete_transferred_files ;;
            b|B) batch_manager ;;
            c|C) show_configuration ;;
            r|R) configure_paths ;;
            t|T) test_nas_destinations 1 1 ;;
            s|S) show_import_folder ;;
            l|L) view_transfer_logs ;;
            0)
                echo
                echo "Exiting."
                exit 0
                ;;
            *)
                echo
                echo "Invalid selection."
                sleep 1
                ;;
        esac
    done
}

mkdir -p "$PATH_DIR" "$VAR_DIR" "$TRANSFER_STATE_DIR" "$LOG_DIR" "$TRANSFERRED_DIR" "$DEFAULT_SOURCE"
touch "$DEFAULT_SOURCE/.gitkeep" "$TRANSFERRED_DIR/.gitkeep" "$LOG_DIR/.gitkeep" "$VAR_DIR/.gitkeep" "$TRANSFER_STATE_DIR/.gitkeep" "$PATH_DIR/.gitkeep" 2>/dev/null || true
migrate_old_config
if ! config_valid; then
    first_time_run
fi
main_menu
