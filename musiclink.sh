#!/usr/bin/env bash
# =============================================================================
#  musiclink.sh  —  Symlink-based music library curator
#  v1.1.0
#
#  All data lives in MUSICLINK_DATA (default: next to this script).
#  Docker: set MUSICLINK_DATA=/config and mount a volume there.
#    musiclink.conf      — saved configuration
#    musiclink.manifest  — symlink registry (TSV)
#
#  Usage: ./musiclink.sh           → interactive menu
#         ./musiclink.sh --help    → flag reference
#         ./musiclink.sh --help-full → full manual
# =============================================================================

set -uo pipefail

# ─── Absolute script location — never relative ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${MUSICLINK_DATA:-${SCRIPT_DIR}}"
CONFIG_FILE="${DATA_DIR}/musiclink.conf"
MANIFEST_FILE="${DATA_DIR}/musiclink.manifest"
VERSION="1.2.0"

# ─── Colors (tput — zero external deps) ──────────────────────────────────────
if tput setaf 1 &>/dev/null 2>&1; then
    C_RED=$(tput setaf 1);    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3); C_BLUE=$(tput setaf 4)
    C_MAGENTA=$(tput setaf 5);C_CYAN=$(tput setaf 6)
    C_BOLD=$(tput bold);      C_DIM=$(tput dim)
    C_RESET=$(tput sgr0);     C_UL=$(tput smul)
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
    C_MAGENTA=""; C_CYAN=""; C_BOLD=""; C_DIM=""
    C_RESET=""; C_UL=""
fi

# ─── Config defaults ──────────────────────────────────────────────────────────
SOURCE_DIR="${SOURCE_DIR:-}"
TARGET_DIR="${TARGET_DIR:-}"
SHORT_PATH_DEPTH=3

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        # Skip blank lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key// /}"        # trim spaces
        value="${value%\"}"     # strip trailing quote
        value="${value#\"}"     # strip leading quote
        case "$key" in
            SOURCE_DIR)       SOURCE_DIR="$value"       ;;
            TARGET_DIR)       TARGET_DIR="$value"       ;;
            SHORT_PATH_DEPTH) SHORT_PATH_DEPTH="$value" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
SOURCE_DIR="${SOURCE_DIR}"
TARGET_DIR="${TARGET_DIR}"
SHORT_PATH_DEPTH=${SHORT_PATH_DEPTH}
EOF
}

# ─── Manifest — TSV: DATE \t SOURCE \t SYMLINK ───────────────────────────────
manifest_init() {
    mkdir -p "$DATA_DIR"
    [[ -f "$MANIFEST_FILE" ]] || touch "$MANIFEST_FILE"
}

manifest_add() {
    local src="$1" sym="$2"
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$src" "$sym" \
        >> "$MANIFEST_FILE"
}

manifest_remove() {
    local sym="$1"
    [[ -f "$MANIFEST_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    awk -F'\t' -v p="$sym" '$3 != p' "$MANIFEST_FILE" > "$tmp"
    mv "$tmp" "$MANIFEST_FILE"
}

manifest_count() {
    [[ -f "$MANIFEST_FILE" ]] || { echo 0; return; }
    local n
    n=$(grep -c '' "$MANIFEST_FILE" 2>/dev/null) || n=0
    # grep -c returns empty lines too — filter blank
    n=$(awk 'NF' "$MANIFEST_FILE" | wc -l | tr -d ' ')
    echo "$n"
}

manifest_exists() {
    local sym="$1"
    [[ -f "$MANIFEST_FILE" ]] || return 1
    awk -F'\t' -v p="$sym" 'BEGIN{f=0} $3==p{f=1} END{exit(f?0:1)}' \
        "$MANIFEST_FILE"
}

# Parallel arrays for loaded manifest
MANIFEST_DATES=()
MANIFEST_SOURCES=()
MANIFEST_SYMLINKS=()

load_manifest() {
    MANIFEST_DATES=()
    MANIFEST_SOURCES=()
    MANIFEST_SYMLINKS=()
    [[ -f "$MANIFEST_FILE" ]] || return 0
    local d s l
    while IFS=$'\t' read -r d s l; do
        [[ -z "${d}${s}${l}" ]] && continue
        MANIFEST_DATES+=("$d")
        MANIFEST_SOURCES+=("$s")
        MANIFEST_SYMLINKS+=("$l")
    done < "$MANIFEST_FILE"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
short_path() {
    # Return last N path components, prefixed with .../
    local path="$1" depth="${2:-$SHORT_PATH_DEPTH}"
    echo "$path" | awk -F'/' -v d="$depth" '{
        if (NF <= d+1) { print $0; next }
        out=""
        for (i=NF-d+1; i<=NF; i++) out = (out=="" ? $i : out"/"$i)
        print ".../" out
    }'
}

link_status() {
    local p="$1"
    if   [[ -L "$p" && -e "$p"   ]]; then echo "OK"
    elif [[ -L "$p" && ! -e "$p" ]]; then echo "DEAD"
    elif [[ -e "$p"              ]]; then echo "CONFLICT"
    else                                   echo "MISSING"
    fi
}

status_badge() {
    # Prints a fixed-width colored badge. Width = 10 visible chars.
    case "$1" in
        OK)       printf '%s' "${C_GREEN}${C_BOLD}[  OK   ]${C_RESET}" ;;
        DEAD)     printf '%s' "${C_RED}${C_BOLD}[ DEAD  ]${C_RESET}"   ;;
        CONFLICT) printf '%s' "${C_YELLOW}${C_BOLD}[ CONF  ]${C_RESET}";;
        MISSING)  printf '%s' "${C_YELLOW}${C_BOLD}[  --   ]${C_RESET}";;
        *)        printf '%s' "${C_DIM}[  ??   ]${C_RESET}"            ;;
    esac
}

confirm() {
    printf '  %s%s%s [y/N] ' "$C_YELLOW" "${1:-Are you sure?}" "$C_RESET"
    local a; read -r a
    [[ "${a,,}" == "y" ]]
}

pause() {
    printf '\n  %sPress Enter to continue...%s' "$C_DIM" "$C_RESET"
    read -r
}

hr() {
    echo "  ${C_DIM}──────────────────────────────────────────────────────────${C_RESET}"
}

# ─── Header ───────────────────────────────────────────────────────────────────
print_header() {
    local count; count="$(manifest_count)"
    local src_d="${SOURCE_DIR:-(not set)}"
    local tgt_d="${TARGET_DIR:-(not set)}"
    # Truncate long paths for display
    [[ ${#src_d} -gt 46 ]] && src_d="...${src_d: -43}"
    [[ ${#tgt_d} -gt 46 ]] && tgt_d="...${tgt_d: -43}"

    echo ""
    echo "  ${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_BOLD}🎵  MusicLink  v%-36s${C_CYAN}${C_BOLD}║${C_RESET}\n" "$VERSION"
    echo "  ${C_CYAN}${C_BOLD}╠══════════════════════════════════════════════════════╣${C_RESET}"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Source :${C_RESET} %-44s${C_CYAN}${C_BOLD}║${C_RESET}\n" "$src_d"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Target :${C_RESET} %-44s${C_CYAN}${C_BOLD}║${C_RESET}\n" "$tgt_d"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Links  :${C_RESET} ${C_GREEN}${C_BOLD}%s${C_RESET} tracked\n" "$count"
    echo "  ${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
}

# ─── File Browser ─────────────────────────────────────────────────────────────
# Sets BROWSER_RESULT to selected absolute path.
# Returns 0 on selection, 1 on cancel.
BROWSER_RESULT=""

file_browser() {
    local mode="${1:-source}"   # "source" or "target"
    local current_dir

    # Pick a sensible start dir
    if   [[ -n "${2:-}" && -d "${2:-}" ]]; then
        current_dir="$(cd "$2" && pwd)"
    elif [[ "$mode" == "source" && -n "$SOURCE_DIR" && -d "$SOURCE_DIR" ]]; then
        current_dir="$SOURCE_DIR"
    elif [[ "$mode" == "target" && -n "$TARGET_DIR" && -d "$TARGET_DIR" ]]; then
        current_dir="$TARGET_DIR"
    else
        current_dir="$HOME"
    fi

    BROWSER_RESULT=""

    while true; do
        clear
        echo ""
        if [[ "$mode" == "source" ]]; then
            echo "  ${C_CYAN}${C_BOLD}╔══ 📂  File Browser — SELECT SOURCE ══════════════════╗${C_RESET}"
        else
            echo "  ${C_CYAN}${C_BOLD}╔══ 📂  File Browser — SELECT DESTINATION ═════════════╗${C_RESET}"
        fi
        # Truncate current dir for display
        local disp_dir="$current_dir"
        [[ ${#disp_dir} -gt 52 ]] && disp_dir="...${disp_dir: -49}"
        printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$disp_dir"
        echo "  ${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
        echo ""

        # Build entry lists (dirs first, then files)
        local -a dirs=() files=()
        local item name
        while IFS= read -r item; do
            name="${item##*/}"
            [[ -z "$name" ]] && continue
            if [[ -d "$item" ]]; then
                dirs+=("$name")
            else
                files+=("$name")
            fi
        done < <(find "$current_dir" -maxdepth 1 -mindepth 1 2>/dev/null | sort)

        # Combined entry array and type array (parallel)
        local -a entries=() etypes=()
        local idx=1

        printf "  ${C_YELLOW}${C_BOLD}[ 0  ]${C_RESET}  ${C_YELLOW}↑  .. go up one level${C_RESET}\n"

        local n
        if [[ ${#dirs[@]} -gt 0 ]]; then
            for n in "${dirs[@]}"; do
                printf "  ${C_BLUE}${C_BOLD}[%-4s]${C_RESET}  ${C_BLUE}📁 %s/${C_RESET}\n" "$idx" "$n"
                entries+=("${current_dir}/${n}")
                etypes+=("dir")
                idx=$((idx + 1))
            done
        fi

        if [[ ${#files[@]} -gt 0 ]]; then
            for n in "${files[@]}"; do
                printf "  ${C_BOLD}[%-4s]${C_RESET}  🎵 %s\n" "$idx" "$n"
                entries+=("${current_dir}/${n}")
                etypes+=("file")
                idx=$((idx + 1))
            done
        fi

        echo ""
        hr
        printf "  ${C_GREEN}${C_BOLD}[ S  ]${C_RESET}  ${C_GREEN}Select THIS directory${C_RESET}  ${C_DIM}(%s)${C_RESET}\n" \
            "$(short_path "$current_dir" 2)"
        if [[ "$mode" == "target" ]]; then
            printf "  ${C_GREEN}${C_BOLD}[ N  ]${C_RESET}  ${C_GREEN}New folder here${C_RESET}\n"
        fi
        printf "  ${C_RED}${C_BOLD}[ Q  ]${C_RESET}  ${C_RED}Cancel${C_RESET}\n"
        echo ""
        printf "  ${C_BOLD}Enter number or command: ${C_RESET}"
        read -r choice

        choice="${choice,,}"

        case "$choice" in
            q)
                BROWSER_RESULT=""
                return 1
                ;;
            s)
                BROWSER_RESULT="$current_dir"
                return 0
                ;;
            0)
                local parent
                parent="$(dirname "$current_dir")"
                [[ "$parent" != "$current_dir" ]] && current_dir="$parent"
                ;;
            n)
                if [[ "$mode" == "target" ]]; then
                    echo ""
                    printf "  ${C_CYAN}New folder name: ${C_RESET}"
                    read -r new_name
                    new_name="${new_name// /_}"   # spaces → underscores
                    if [[ -n "$new_name" ]]; then
                        local new_path="${current_dir}/${new_name}"
                        if mkdir -p "$new_path"; then
                            echo "  ${C_GREEN}✓ Created: $new_path${C_RESET}"
                            sleep 0.6
                            current_dir="$new_path"
                        else
                            echo "  ${C_RED}Failed to create directory.${C_RESET}"
                            sleep 1
                        fi
                    fi
                else
                    echo "  ${C_RED}N only available in target mode.${C_RESET}"; sleep 0.5
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local eidx=$((choice - 1))
                    if [[ $eidx -ge 0 && $eidx -lt ${#entries[@]} ]]; then
                        local epath="${entries[$eidx]}"
                        local etype="${etypes[$eidx]}"
                        if [[ "$etype" == "dir" ]]; then
                            current_dir="$epath"
                        else
                            # File selected — confirm and return
                            echo ""
                            echo "  ${C_DIM}Selected: ${C_RESET}${C_GREEN}$epath${C_RESET}"
                            if confirm "Use this file?"; then
                                BROWSER_RESULT="$epath"
                                return 0
                            fi
                        fi
                    else
                        echo "  ${C_RED}No entry #${choice}.${C_RESET}"; sleep 0.5
                    fi
                else
                    echo "  ${C_RED}Invalid input.${C_RESET}"; sleep 0.5
                fi
                ;;
        esac
    done
}

# ─── cmd_add ──────────────────────────────────────────────────────────────────
# cmd_add [source_path [symlink_path]]
cmd_add() {
    local source_path="${1:-}"
    local symlink_path="${2:-}"

    # ── Step 1: source ────────────────────────────────────────────────────────
    if [[ -z "$source_path" ]]; then
        clear
        echo ""
        echo "  ${C_CYAN}${C_BOLD}── Add Link ─────────────────────────────────────────────${C_RESET}"
        echo "  ${C_DIM}Step 1 of 2: Browse to the file or folder you want to link.${C_RESET}"
        echo "  ${C_DIM}Select a file directly, or press [S] to link a whole folder.${C_RESET}"
        echo ""
        pause

        if ! file_browser "source"; then
            echo "  ${C_YELLOW}Cancelled.${C_RESET}"; pause; return
        fi
        source_path="$BROWSER_RESULT"
    fi

    # Validate
    if [[ ! -e "$source_path" ]]; then
        echo ""
        echo "  ${C_RED}Source does not exist:${C_RESET} $source_path"
        pause; return
    fi

    # Resolve to absolute — prevents broken symlinks if relative path passed via -a flag
    if [[ "${source_path}" != /* ]]; then
        source_path="$(cd "$(dirname "$source_path")" 2>/dev/null && pwd)/$(basename "$source_path")" \
            || { echo "  ${C_RED}Cannot resolve absolute path.${C_RESET}"; pause; return; }
    fi

    # ── Step 2: destination ───────────────────────────────────────────────────
    if [[ -z "$symlink_path" ]]; then
        clear
        echo ""
        echo "  ${C_CYAN}${C_BOLD}── Add Link ─────────────────────────────────────────────${C_RESET}"
        echo "  ${C_DIM}Step 2 of 2: Choose destination directory for the symlink.${C_RESET}"
        echo "  ${C_DIM}Linking: ${C_RESET}${C_GREEN}$source_path${C_RESET}"
        echo ""
        pause

        if ! file_browser "target"; then
            echo "  ${C_YELLOW}Cancelled.${C_RESET}"; pause; return
        fi
        local dest_dir="$BROWSER_RESULT"
        local base; base="$(basename "$source_path")"
        symlink_path="${dest_dir}/${base}"
    fi

    # Duplicate check
    if manifest_exists "$symlink_path"; then
        echo ""
        echo "  ${C_YELLOW}Already in manifest:${C_RESET} $symlink_path"
        pause; return
    fi

    # Conflict on disk
    if [[ -e "$symlink_path" || -L "$symlink_path" ]]; then
        echo ""
        echo "  ${C_YELLOW}Path already exists on disk:${C_RESET} $symlink_path"
        if ! confirm "Overwrite?"; then
            echo "  ${C_YELLOW}Cancelled.${C_RESET}"; pause; return
        fi
        rm -rf "$symlink_path"
    fi

    # ── Confirm ───────────────────────────────────────────────────────────────
    clear
    echo ""
    echo "  ${C_CYAN}${C_BOLD}── Add Link — Confirm ───────────────────────────────────${C_RESET}"
    echo ""
    echo "  ${C_DIM}Source  :${C_RESET}  ${C_GREEN}$source_path${C_RESET}"
    echo "  ${C_DIM}Symlink :${C_RESET}  ${C_BLUE}$symlink_path${C_RESET}"
    echo "  ${C_DIM}          (symlink → source)${C_RESET}"
    echo ""

    if ! confirm "Create this symlink?"; then
        echo "  ${C_YELLOW}Cancelled.${C_RESET}"; pause; return
    fi

    mkdir -p "$(dirname "$symlink_path")"

    if ln -s "$source_path" "$symlink_path"; then
        manifest_add "$source_path" "$symlink_path"
        echo ""
        echo "  ${C_GREEN}${C_BOLD}✓ Symlink created and recorded in manifest.${C_RESET}"
        echo "  ${C_DIM}  $symlink_path${C_RESET}"
    else
        echo "  ${C_RED}Failed to create symlink.${C_RESET}"
    fi

    pause
}

# ─── cmd_remove ───────────────────────────────────────────────────────────────
cmd_remove() {
    # Can be called with an explicit symlink path (from flags) or interactively
    local explicit_path="${1:-}"

    if [[ -n "$explicit_path" ]]; then
        if manifest_exists "$explicit_path"; then
            manifest_remove "$explicit_path"
            [[ -L "$explicit_path" ]] && rm "$explicit_path"
            echo "  ${C_GREEN}✓ Removed:${C_RESET} $explicit_path"
        else
            echo "  ${C_YELLOW}Not found in manifest:${C_RESET} $explicit_path"
        fi
        return
    fi

    # ── Interactive ───────────────────────────────────────────────────────────
    load_manifest

    clear
    echo ""
    echo "  ${C_CYAN}${C_BOLD}── Remove Link ──────────────────────────────────────────${C_RESET}"
    echo ""

    if [[ ${#MANIFEST_SYMLINKS[@]} -eq 0 ]]; then
        echo "  ${C_YELLOW}No links in manifest.${C_RESET}"; pause; return
    fi

    local i
    for i in "${!MANIFEST_SYMLINKS[@]}"; do
        local st; st="$(link_status "${MANIFEST_SYMLINKS[$i]}")"
        printf "  ${C_BOLD}[%3d]${C_RESET}  " "$((i+1))"
        status_badge "$st"
        printf "  %s\n" "$(short_path "${MANIFEST_SYMLINKS[$i]}")"
    done

    echo ""
    hr
    echo "  ${C_DIM}Enter number to remove, or Q to cancel.${C_RESET}"
    echo ""
    printf "  ${C_BOLD}Choice: ${C_RESET}"
    read -r choice

    [[ "${choice,,}" == "q" || -z "$choice" ]] && return

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [[ $idx -ge 0 && $idx -lt ${#MANIFEST_SYMLINKS[@]} ]]; then
            local sym="${MANIFEST_SYMLINKS[$idx]}"
            local src="${MANIFEST_SOURCES[$idx]}"
            echo ""
            echo "  ${C_DIM}Symlink :${C_RESET}  ${C_BLUE}$sym${C_RESET}"
            echo "  ${C_DIM}Source  :${C_RESET}  ${C_GREEN}$src${C_RESET}"
            echo ""

            local del_disk=false
            if [[ -L "$sym" ]]; then
                if confirm "Also delete the symlink file from disk?"; then
                    del_disk=true
                fi
            fi

            echo ""
            if confirm "Remove from manifest?"; then
                manifest_remove "$sym"
                if $del_disk; then
                    rm "$sym"
                    echo "  ${C_GREEN}✓ Symlink deleted from disk.${C_RESET}"
                fi
                echo "  ${C_GREEN}${C_BOLD}✓ Removed from manifest.${C_RESET}"
            else
                echo "  ${C_YELLOW}Cancelled.${C_RESET}"
            fi
        else
            echo "  ${C_RED}Invalid number.${C_RESET}"
        fi
    else
        echo "  ${C_RED}Invalid input.${C_RESET}"
    fi

    pause
}

# ─── cmd_list ─────────────────────────────────────────────────────────────────
# mode: "short" | "full"
# Internal toggle lets user flip inside the view.
cmd_list() {
    local mode="${1:-short}"
    load_manifest

    while true; do
        clear
        echo ""
        if [[ "$mode" == "full" ]]; then
            echo "  ${C_CYAN}${C_BOLD}── All Links  ${C_DIM}(full paths — press T to toggle short)${C_RESET}"
        else
            echo "  ${C_CYAN}${C_BOLD}── All Links  ${C_DIM}(short paths — press T to toggle full)${C_RESET}"
        fi
        echo ""

        if [[ ${#MANIFEST_SYMLINKS[@]} -eq 0 ]]; then
            echo "  ${C_YELLOW}No links in manifest yet. Use [1] from the main menu to add one.${C_RESET}"
            echo ""
            hr
            printf "  ${C_BOLD}[Q] Back${C_RESET}\n\n"
            printf "  ${C_BOLD}Choice: ${C_RESET}"
            read -r choice
            return
        fi

        # Column header
        printf "  ${C_BOLD}${C_UL}%-5s  %-11s  %-10s  %-34s${C_RESET}\n" \
            "#" "ADDED" "STATUS" "SYMLINK (destination)"
        echo ""

        local i
        for i in "${!MANIFEST_SYMLINKS[@]}"; do
            local num=$((i+1))
            local date_s="${MANIFEST_DATES[$i]:0:10}"
            local sym="${MANIFEST_SYMLINKS[$i]}"
            local st; st="$(link_status "$sym")"

            local sym_display
            if [[ "$mode" == "full" ]]; then
                sym_display="$sym"
            else
                sym_display="$(short_path "$sym")"
            fi

            printf "  ${C_BOLD}%-5s${C_RESET}  ${C_DIM}%-11s${C_RESET}  " "$num" "$date_s"
            status_badge "$st"
            printf "  %s\n" "$sym_display"

            # In full mode, show source on the next line indented
            if [[ "$mode" == "full" ]]; then
                printf "  %5s  %11s  %10s  ${C_DIM}src: %s${C_RESET}\n" \
                    "" "" "" "${MANIFEST_SOURCES[$i]}"
                echo ""
            fi
        done

        echo ""
        hr
        echo "  ${C_CYAN}${C_BOLD}[1]${C_RESET}  Inspect a link in detail"
        echo "  ${C_CYAN}${C_BOLD}[2]${C_RESET}  Toggle short/full path view"
        echo "  ${C_CYAN}${C_BOLD}[0]${C_RESET}  Back to menu"
        echo ""
        printf "  ${C_BOLD}Choice: ${C_RESET}"
        read -r choice

        case "$choice" in
            1) cmd_info_interactive ;;
            2) [[ "$mode" == "short" ]] && mode="full" || mode="short" ;;
            0|"") return ;;
        esac
    done
}

# ─── cmd_info ─────────────────────────────────────────────────────────────────
# $1 = 0-based index into loaded manifest arrays
cmd_info() {
    load_manifest
    local idx="${1:-0}"

    if [[ $idx -lt 0 || $idx -ge ${#MANIFEST_SYMLINKS[@]} ]]; then
        echo "  ${C_RED}Invalid link index.${C_RESET}"; pause; return
    fi

    local date="${MANIFEST_DATES[$idx]}"
    local src="${MANIFEST_SOURCES[$idx]}"
    local sym="${MANIFEST_SYMLINKS[$idx]}"
    local st; st="$(link_status "$sym")"

    local type_str="Unknown"
    if   [[ -d "$src" ]]; then type_str="Directory"
    elif [[ -f "$src" ]]; then type_str="File"
    fi

    local resolves="(symlink not present on disk)"
    if [[ -L "$sym" ]]; then
        resolves="$(readlink "$sym")"
    fi

    local src_exists="${C_RED}No (source moved or deleted)${C_RESET}"
    [[ -e "$src" ]] && src_exists="${C_GREEN}Yes${C_RESET}"

    clear
    echo ""
    echo "  ${C_CYAN}${C_BOLD}╔══ Link Detail ══════════════════════════════════════════╗${C_RESET}"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Entry #${C_RESET}   : ${C_BOLD}%d of %d${C_RESET}\n" \
        "$((idx+1))" "${#MANIFEST_SYMLINKS[@]}"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Status${C_RESET}    : "
    status_badge "$st"; echo ""
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Added${C_RESET}     : ${C_YELLOW}%s${C_RESET}\n" "$date"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Type${C_RESET}      : %s\n" "$type_str"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}Src exists${C_RESET}: %b\n" "$src_exists"
    echo "  ${C_CYAN}${C_BOLD}╠══ Source (absolute path) ═══════════════════════════════╣${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_GREEN}$src${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}╠══ Symlink (absolute path) ══════════════════════════════╣${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_BLUE}$sym${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}╠══ Resolves to ══════════════════════════════════════════╣${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}"
    printf "  ${C_CYAN}${C_BOLD}║${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$resolves"
    echo "  ${C_CYAN}${C_BOLD}║${C_RESET}"
    echo "  ${C_CYAN}${C_BOLD}╚════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""

    # Navigate prev/next
    hr
    local prev_hint="" next_hint=""
    [[ $idx -gt 0 ]] && \
        prev_hint="${C_CYAN}[P]${C_RESET} prev  "
    [[ $idx -lt $((${#MANIFEST_SYMLINKS[@]}-1)) ]] && \
        next_hint="${C_CYAN}[N]${C_RESET} next  "
    printf "  %b%b${C_CYAN}[Q]${C_RESET} back\n\n" "$prev_hint" "$next_hint"
    printf "  ${C_BOLD}Choice: ${C_RESET}"
    read -r choice

    case "${choice,,}" in
        p) [[ $idx -gt 0 ]] && cmd_info "$((idx-1))" ;;
        n) [[ $idx -lt $((${#MANIFEST_SYMLINKS[@]}-1)) ]] && cmd_info "$((idx+1))" ;;
    esac
}

cmd_info_interactive() {
    load_manifest

    if [[ ${#MANIFEST_SYMLINKS[@]} -eq 0 ]]; then
        echo ""; echo "  ${C_YELLOW}No links in manifest.${C_RESET}"; pause; return
    fi

    echo ""
    echo "  ${C_DIM}Enter link number (1–${#MANIFEST_SYMLINKS[@]}) to inspect:${C_RESET}"
    echo ""

    local i
    for i in "${!MANIFEST_SYMLINKS[@]}"; do
        local st; st="$(link_status "${MANIFEST_SYMLINKS[$i]}")"
        printf "  ${C_BOLD}[%3d]${C_RESET}  " "$((i+1))"
        status_badge "$st"
        printf "  %s\n" "$(short_path "${MANIFEST_SYMLINKS[$i]}")"
    done

    echo ""
    printf "  ${C_BOLD}Link #: ${C_RESET}"
    read -r choice

    [[ "${choice,,}" == "q" || -z "$choice" ]] && return

    if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#MANIFEST_SYMLINKS[@]} ]]; then
        cmd_info "$((choice - 1))"
    else
        echo "  ${C_RED}Invalid.${C_RESET}"; sleep 0.5
    fi
}

# ─── cmd_sync ─────────────────────────────────────────────────────────────────
cmd_sync() {
    load_manifest
    clear
    echo ""
    echo "  ${C_CYAN}${C_BOLD}── Sync — Rebuilding links from manifest ────────────────${C_RESET}"
    echo ""

    if [[ ${#MANIFEST_SYMLINKS[@]} -eq 0 ]]; then
        echo "  ${C_YELLOW}Manifest is empty. Nothing to sync.${C_RESET}"
        pause; return
    fi

    local ok=0 skipped=0 failed=0
    local i
    for i in "${!MANIFEST_SYMLINKS[@]}"; do
        local src="${MANIFEST_SOURCES[$i]}"
        local sym="${MANIFEST_SYMLINKS[$i]}"
        local short; short="$(short_path "$sym")"

        if [[ -L "$sym" && -e "$sym" ]]; then
            printf "  ${C_DIM}  SKIP  %-52s (valid, exists)${C_RESET}\n" "$short"
            skipped=$((skipped + 1))

        elif [[ ! -e "$src" ]]; then
            printf "  ${C_RED}  FAIL  %-52s source missing${C_RESET}\n" "$short"
            failed=$((failed + 1))

        else
            mkdir -p "$(dirname "$sym")"
            [[ -L "$sym" ]] && rm "$sym"   # Remove dead symlink before recreating
            if ln -s "$src" "$sym"; then
                printf "  ${C_GREEN}  OK    %-52s created${C_RESET}\n" "$short"
                ok=$((ok + 1))
            else
                printf "  ${C_RED}  FAIL  %-52s ln failed${C_RESET}\n" "$short"
                failed=$((failed + 1))
            fi
        fi
    done

    echo ""
    hr
    printf "  ${C_GREEN}${C_BOLD}Created: %-4s${C_RESET}  ${C_DIM}Skipped: %-4s${C_RESET}  ${C_RED}${C_BOLD}Failed: %s${C_RESET}\n" \
        "$ok" "$skipped" "$failed"
    echo ""
    [[ $failed -gt 0 ]] && \
        echo "  ${C_DIM}Tip: failed links have sources that no longer exist at the recorded path.${C_RESET}"

    pause
}

# ─── cmd_verify ───────────────────────────────────────────────────────────────
cmd_verify() {
    load_manifest
    clear
    echo ""
    echo "  ${C_CYAN}${C_BOLD}── Verify — Checking all links ──────────────────────────${C_RESET}"
    echo ""

    if [[ ${#MANIFEST_SYMLINKS[@]} -eq 0 ]]; then
        echo "  ${C_YELLOW}Manifest is empty.${C_RESET}"; pause; return
    fi

    local ok=0 dead=0 conflict=0 missing=0
    local i
    for i in "${!MANIFEST_SYMLINKS[@]}"; do
        local sym="${MANIFEST_SYMLINKS[$i]}"
        local src="${MANIFEST_SOURCES[$i]}"
        local st; st="$(link_status "$sym")"
        local short; short="$(short_path "$sym")"
        local num=$((i+1))

        printf "  ${C_BOLD}[%3d]${C_RESET}  " "$num"
        status_badge "$st"
        printf "  %s\n" "$short"

        case "$st" in
            OK)
                ok=$((ok + 1))
                ;;
            DEAD)
                printf "         ${C_RED}Source missing: %s${C_RESET}\n" "$src"
                dead=$((dead + 1))
                ;;
            CONFLICT)
                printf "         ${C_YELLOW}Real file/dir at symlink path (not a symlink!)${C_RESET}\n"
                conflict=$((conflict + 1))
                ;;
            MISSING)
                printf "         ${C_YELLOW}Not on disk — run Sync to recreate${C_RESET}\n"
                missing=$((missing + 1))
                ;;
        esac
    done

    echo ""
    hr
    printf "  ${C_GREEN}${C_BOLD}OK: %-4s${C_RESET}  " "$ok"
    printf "${C_RED}${C_BOLD}Dead: %-4s${C_RESET}  " "$dead"
    printf "${C_YELLOW}Conflict: %-4s${C_RESET}  " "$conflict"
    printf "${C_YELLOW}Missing: %s${C_RESET}\n" "$missing"
    echo ""

    if [[ $dead -gt 0 || $missing -gt 0 ]]; then
        echo "  ${C_DIM}→ Dead: sources moved or deleted. Update manifest manually or re-add.${C_RESET}"
        echo "  ${C_DIM}→ Missing: run Sync [S] to recreate from manifest.${C_RESET}"
    fi
    if [[ $conflict -gt 0 ]]; then
        echo "  ${C_DIM}→ Conflict: a real file/folder occupies the symlink destination.${C_RESET}"
        echo "  ${C_DIM}  Remove it manually then run Sync.${C_RESET}"
    fi

    pause
}

# ─── cmd_new_folder ───────────────────────────────────────────────────────────
cmd_new_folder() {
    local explicit_path="${1:-}"

    if [[ -n "$explicit_path" ]]; then
        # Resolve absolute path
        if [[ "$explicit_path" != /* ]]; then
            [[ -z "$TARGET_DIR" ]] && {
                echo "  ${C_RED}Target dir not set and path is not absolute.${C_RESET}"
                echo "  ${C_DIM}Use --set-target first, or pass an absolute path.${C_RESET}"
                return 1
            }
            explicit_path="${TARGET_DIR}/${explicit_path}"
        fi
        mkdir -p "$explicit_path"
        echo "  ${C_GREEN}✓ Created: $explicit_path${C_RESET}"
        return
    fi

    # ── Interactive ───────────────────────────────────────────────────────────
    clear
    echo ""
    echo "  ${C_CYAN}${C_BOLD}── New Folder in Target ─────────────────────────────────${C_RESET}"
    echo ""

    if [[ -z "$TARGET_DIR" ]]; then
        echo "  ${C_YELLOW}Target dir not set. Go to Config [C] first.${C_RESET}"
        pause; return
    fi

    echo "  ${C_DIM}Target root: $TARGET_DIR${C_RESET}"
    echo ""
    echo "  ${C_DIM}You can nest folders with slashes, e.g.:  Jazz/Bebop/1950s${C_RESET}"
    printf "  ${C_BOLD}Folder name or path: ${C_RESET}"
    read -r folder_name

    if [[ -z "$folder_name" ]]; then
        echo "  ${C_YELLOW}Cancelled.${C_RESET}"; pause; return
    fi

    local new_path="${TARGET_DIR}/${folder_name}"
    if mkdir -p "$new_path"; then
        echo ""
        echo "  ${C_GREEN}${C_BOLD}✓ Created: $new_path${C_RESET}"
    else
        echo "  ${C_RED}Failed to create directory.${C_RESET}"
    fi

    pause
}

# ─── cmd_config_menu ──────────────────────────────────────────────────────────
cmd_config_menu() {
    while true; do
        clear
        echo ""
        echo "  ${C_CYAN}${C_BOLD}── Config ────────────────────────────────────────────────${C_RESET}"
        echo ""
        echo "  ${C_DIM}Config file: $CONFIG_FILE${C_RESET}"
        echo ""
        printf "  ${C_DIM}Source dir   :${C_RESET}  ${C_GREEN}%s${C_RESET}\n" "${SOURCE_DIR:-(not set)}"
        printf "  ${C_DIM}Target dir   :${C_RESET}  ${C_GREEN}%s${C_RESET}\n" "${TARGET_DIR:-(not set)}"
        printf "  ${C_DIM}Short depth  :${C_RESET}  ${C_GREEN}%s${C_RESET}  ${C_DIM}(path components in short view)${C_RESET}\n" \
            "$SHORT_PATH_DEPTH"
        echo ""
        hr
        echo "  ${C_CYAN}${C_BOLD}[1]${C_RESET}  Set source dir     ${C_DIM}(browse)${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[2]${C_RESET}  Set source dir     ${C_DIM}(type absolute path)${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[3]${C_RESET}  Set target dir     ${C_DIM}(browse)${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[4]${C_RESET}  Set target dir     ${C_DIM}(type absolute path)${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[5]${C_RESET}  Set short path depth"
        echo "  ${C_CYAN}${C_BOLD}[0]${C_RESET}  Back"
        echo ""
        printf "  ${C_BOLD}Choice: ${C_RESET}"
        read -r choice
        echo ""

        case "$choice" in
            1)
                if file_browser "source"; then
                    SOURCE_DIR="$BROWSER_RESULT"
                    save_config
                    echo "  ${C_GREEN}✓ Source set: $SOURCE_DIR${C_RESET}"; sleep 1
                fi
                ;;
            2)
                echo ""
                printf "  ${C_CYAN}Absolute source path: ${C_RESET}"
                read -r new_src
                if [[ -d "$new_src" ]]; then
                    SOURCE_DIR="$(cd "$new_src" && pwd)"
                    save_config
                    echo "  ${C_GREEN}✓ Source set: $SOURCE_DIR${C_RESET}"
                else
                    echo "  ${C_RED}Directory not found: $new_src${C_RESET}"
                fi
                sleep 1
                ;;
            3)
                if file_browser "target"; then
                    TARGET_DIR="$BROWSER_RESULT"
                    save_config
                    echo "  ${C_GREEN}✓ Target set: $TARGET_DIR${C_RESET}"; sleep 1
                fi
                ;;
            4)
                echo ""
                printf "  ${C_CYAN}Absolute target path: ${C_RESET}"
                read -r new_tgt
                if [[ -d "$new_tgt" ]]; then
                    TARGET_DIR="$(cd "$new_tgt" && pwd)"
                    save_config
                    echo "  ${C_GREEN}✓ Target set: $TARGET_DIR${C_RESET}"
                elif confirm "Directory doesn't exist. Create it?"; then
                    mkdir -p "$new_tgt"
                    TARGET_DIR="$(cd "$new_tgt" && pwd)"
                    save_config
                    echo "  ${C_GREEN}✓ Created and set: $TARGET_DIR${C_RESET}"
                fi
                sleep 1
                ;;
            5)
                echo ""
                printf "  ${C_CYAN}Short path depth (current: %d): ${C_RESET}" "$SHORT_PATH_DEPTH"
                read -r new_depth
                if [[ "$new_depth" =~ ^[0-9]+$ && $new_depth -gt 0 ]]; then
                    SHORT_PATH_DEPTH=$new_depth
                    save_config
                    echo "  ${C_GREEN}✓ Depth set to $SHORT_PATH_DEPTH${C_RESET}"
                else
                    echo "  ${C_RED}Invalid. Enter a positive integer.${C_RESET}"
                fi
                sleep 1
                ;;
            0|"") break ;;
            *) echo "  ${C_RED}Enter a number from the menu above.${C_RESET}"; sleep 0.5 ;;
        esac
    done
}

# ─── cmd_edit_manifest ────────────────────────────────────────────────────────
cmd_edit_manifest() {
    manifest_init
    local editor="${EDITOR:-${VISUAL:-nano}}"
    echo ""
    echo "  ${C_DIM}Opening manifest in: $editor${C_RESET}"
    echo "  ${C_DIM}Format: DATE<TAB>SOURCE_PATH<TAB>SYMLINK_PATH${C_RESET}"
    echo "  ${C_YELLOW}Warning: editing paths manually won't move symlinks on disk.${C_RESET}"
    sleep 1
    "$editor" "$MANIFEST_FILE"
}

# ─── Help ─────────────────────────────────────────────────────────────────────
cmd_help_short() {
    echo ""
    echo "  ${C_CYAN}${C_BOLD}MusicLink v${VERSION}${C_RESET}  —  Quick Flag Reference"
    echo ""
    echo "  ${C_BOLD}Usage:${C_RESET}  ./musiclink.sh [FLAGS]"
    echo "  ${C_DIM}Run without flags to enter the interactive menu.${C_RESET}"
    echo ""
    echo "  ${C_BOLD}${C_UL}Flag                            Description${C_RESET}"
    local fmt="  ${C_CYAN}%-33s${C_RESET} %s\n"
    printf "$fmt" "-a, --add <source>"          "Add a link (prompts for destination)"
    printf "$fmt" "-a <src> -d <dest>"          "Add with explicit destination path"
    printf "$fmt" "-r, --remove <symlink>"      "Remove link + manifest entry"
    printf "$fmt" "-l, --list"                  "List all links (short paths)"
    printf "$fmt" "-L, --list-full"             "List all links (full paths)"
    printf "$fmt" "-i, --info <symlink>"        "Show full detail for one link"
    printf "$fmt" "-s, --sync"                  "Rebuild all links from manifest"
    printf "$fmt" "-v, --verify"                "Check all links for issues"
    printf "$fmt" "-n, --new-folder <path>"     "Create folder (absolute or relative to target)"
    printf "$fmt" "--set-source <dir>"          "Set and save default source dir"
    printf "$fmt" "--set-target <dir>"          "Set and save default target dir"
    printf "$fmt" "--set-depth <n>"             "Set short-path display depth"
    printf "$fmt" "-D, --data-dir <path>"       "Override config/manifest directory"
    printf "$fmt" "-h, --help"                  "This quick reference"
    printf "$fmt" "--help-full"                 "Full manual"
    echo ""
    echo "  ${C_DIM}Data files (${DATA_DIR}):${C_RESET}"
    echo "  ${C_DIM}  $CONFIG_FILE${C_RESET}"
    echo "  ${C_DIM}  $MANIFEST_FILE${C_RESET}"
    echo ""
}

cmd_help_full() {
    clear
    cat <<EOF

  ${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗
  ║          MusicLink v${VERSION}  —  Full Manual                     ║
  ╚══════════════════════════════════════════════════════════════╝${C_RESET}

  ${C_BOLD}OVERVIEW${C_RESET}
    MusicLink curates a shared music library using symbolic links.
    Your original files never move. Point it at albums, folders, or
    individual files in your main library, and it places symlinks in
    a "shared" target directory — which any music player can import
    as its library root.

    Incremental: add more links anytime. Re-run Sync after any
    machine move and all links are rebuilt from the manifest.

  ${C_BOLD}DATA FILES — stored in ${DATA_DIR}, backup them together${C_RESET}
    ${C_GREEN}musiclink.conf${C_RESET}
        KEY=VALUE config. Set source/target dirs and display prefs.

    ${C_GREEN}musiclink.manifest${C_RESET}
        Tab-separated registry of every symlink. One entry per line:
        ${C_DIM}DATE_ADDED (ISO 8601) <TAB> SOURCE_PATH <TAB> SYMLINK_PATH${C_RESET}
        Example:
        ${C_DIM}2026-05-18T14:32:00  /Music/Jazz/Coltrane  /Shared/Jazz/Coltrane${C_RESET}

  ${C_BOLD}INTERACTIVE MENU${C_RESET}
    Run ./musiclink.sh with no arguments. Type a number and press Enter.

  ${C_BOLD}FILE BROWSER${C_RESET}
    A number-driven directory navigator:
    ${C_CYAN}[0]${C_RESET}         Go up one directory level
    ${C_CYAN}[1..N]${C_RESET}      Enter directory or select file
    ${C_CYAN}[S]${C_RESET}         Select the current directory (use whole folder)
    ${C_CYAN}[N]${C_RESET}         New folder here (target mode only)
    ${C_CYAN}[Q]${C_RESET}         Cancel

  ${C_BOLD}LIST VIEWS${C_RESET}
    ${C_CYAN}[3]${C_RESET}  Short view — last ${SHORT_PATH_DEPTH} path components  (.../artist/album)
    ${C_CYAN}[4]${C_RESET}  Full view  — complete absolute paths
    ${C_CYAN}[2]${C_RESET}  Toggle between short and full inside the list view
    ${C_CYAN}[1]${C_RESET}  Inspect a single link — shows both paths, date, status,
         and what the symlink resolves to on disk. Navigate P/N
         for previous/next.

  ${C_BOLD}LINK STATUS BADGES${C_RESET}
    ${C_GREEN}[  OK   ]${C_RESET}   Symlink exists, source is reachable
    ${C_RED}[ DEAD  ]${C_RESET}   Symlink exists but source moved or deleted
    ${C_YELLOW}[ CONF  ]${C_RESET}   A real file/dir sits at the symlink path (not a link)
    ${C_YELLOW}[  --   ]${C_RESET}   In manifest but not on disk — run Sync

  ${C_BOLD}SYNC vs VERIFY${C_RESET}
    Verify  — read-only report. Makes no changes.
    Sync    — recreates missing/broken symlinks from manifest.
              Skips valid existing links. Idempotent and safe.

  ${C_BOLD}FLAG QUICK EXAMPLES${C_RESET}
    # First-time setup
    ./musiclink.sh --set-source "/Volumes/Music"
    ./musiclink.sh --set-target "/Volumes/Shared/MyLibrary"

    # Add an album (destination chosen interactively)
    ./musiclink.sh -a "/Volumes/Music/Beatles/Abbey Road"

    # Add with explicit destination
    ./musiclink.sh -a "/Volumes/Music/Beatles/Abbey Road" \\
                   -d "/Volumes/Shared/MyLibrary/Rock/Abbey Road"

    # Remove a link (also removes the symlink file from disk)
    ./musiclink.sh -r "/Volumes/Shared/MyLibrary/Rock/Abbey Road"

    # Verify and sync
    ./musiclink.sh -v
    ./musiclink.sh -s

    # Create a category folder first, then add to it
    ./musiclink.sh -n "Mood/Late Night"
    ./musiclink.sh -a "/Volumes/Music/Coltrane" -d "/Volumes/Shared/MyLibrary/Mood/Late Night/Coltrane"

    # List with full paths
    ./musiclink.sh -L

  ${C_BOLD}TIPS${C_RESET}
    • Backup strategy: zip the folder containing musiclink.sh,
      musiclink.conf, and musiclink.manifest. That's everything.
    • After moving to a new machine: update source/target in config,
      run --sync. All symlinks rebuild in seconds.
    • The manifest is plain text — safe to edit with any text editor
      (use [E] in the menu to open in \$EDITOR).
    • Spaces in paths are fully supported everywhere.

EOF
    pause
}

# ─── Main Menu ────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        print_header
        echo "  ${C_CYAN}${C_BOLD}[1]${C_RESET}   Add link          ${C_DIM}file browser → create symlink${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[2]${C_RESET}   Remove link        ${C_DIM}pick from list${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[3]${C_RESET}   List links         ${C_DIM}short path view${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[4]${C_RESET}   List links         ${C_DIM}full path view${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[5]${C_RESET}   Inspect link       ${C_DIM}full detail on one entry${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[6]${C_RESET}   Sync               ${C_DIM}rebuild all links from manifest${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[7]${C_RESET}   Verify             ${C_DIM}check for broken / missing links${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[8]${C_RESET}   New folder         ${C_DIM}create a folder in target dir${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[9]${C_RESET}   Config             ${C_DIM}set source/target/depth${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[10]${C_RESET}  Edit manifest      ${C_DIM}open raw TSV in \$EDITOR${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[11]${C_RESET}  Help               ${C_DIM}full manual${C_RESET}"
        echo "  ${C_CYAN}${C_BOLD}[0]${C_RESET}   Quit"
        echo ""
        printf "  ${C_BOLD}Choice: ${C_RESET}"
        read -r choice
        echo ""

        case "$choice" in
            1)  cmd_add ;;
            2)  cmd_remove ;;
            3)  cmd_list short ;;
            4)  cmd_list full ;;
            5)  cmd_info_interactive ;;
            6)  cmd_sync ;;
            7)  cmd_verify ;;
            8)  cmd_new_folder ;;
            9)  cmd_config_menu ;;
            10) cmd_edit_manifest ;;
            11) cmd_help_full ;;
            0)  echo ""; echo "  ${C_DIM}Goodbye.${C_RESET}"; echo ""; exit 0 ;;
            *)  echo "  ${C_RED}Enter a number from the menu above.${C_RESET}"; sleep 0.6 ;;
        esac
    done
}

# ─── Flag / CLI mode ─────────────────────────────────────────────────────────
FLAG_MODE=false
_PENDING_ADD_SOURCE=""
_PENDING_ADD_DEST=""

parse_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in

            # ── Add ──────────────────────────────────────────────────────────
            -a|--add)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}$1 requires a path.${C_RESET}"; exit 1; }
                _PENDING_ADD_SOURCE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" 2>/dev/null \
                    || _PENDING_ADD_SOURCE="$2"
                FLAG_MODE=true
                shift 2
                ;;

            -d|--dest)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}$1 requires a path.${C_RESET}"; exit 1; }
                _PENDING_ADD_DEST="$2"
                shift 2
                ;;

            # ── Remove ───────────────────────────────────────────────────────
            -r|--remove)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}$1 requires a path.${C_RESET}"; exit 1; }
                FLAG_MODE=true
                cmd_remove "$2"
                shift 2
                ;;

            # ── List ─────────────────────────────────────────────────────────
            -l|--list)
                FLAG_MODE=true
                cmd_list short
                shift
                ;;

            -L|--list-full)
                FLAG_MODE=true
                cmd_list full
                shift
                ;;

            # ── Info ─────────────────────────────────────────────────────────
            -i|--info)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}$1 requires a symlink path.${C_RESET}"; exit 1; }
                FLAG_MODE=true
                load_manifest
                local found=false jj
                for jj in "${!MANIFEST_SYMLINKS[@]}"; do
                    if [[ "${MANIFEST_SYMLINKS[$jj]}" == "$2" ]]; then
                        cmd_info "$jj"
                        found=true
                        break
                    fi
                done
                $found || echo "  ${C_YELLOW}Not found in manifest: $2${C_RESET}"
                shift 2
                ;;

            # ── Sync / Verify ─────────────────────────────────────────────
            -s|--sync)
                FLAG_MODE=true
                cmd_sync
                shift
                ;;

            -v|--verify)
                FLAG_MODE=true
                cmd_verify
                shift
                ;;

            # ── New folder ───────────────────────────────────────────────────
            -n|--new-folder)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}$1 requires a path.${C_RESET}"; exit 1; }
                FLAG_MODE=true
                cmd_new_folder "$2"
                shift 2
                ;;

            # ── Config setters ───────────────────────────────────────────────
            --set-source)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}--set-source requires a path.${C_RESET}"; exit 1; }
                FLAG_MODE=true
                if [[ -d "$2" ]]; then
                    SOURCE_DIR="$(cd "$2" && pwd)"
                    save_config
                    echo "  ${C_GREEN}✓ Source set: $SOURCE_DIR${C_RESET}"
                else
                    echo "  ${C_RED}Directory not found: $2${C_RESET}"; exit 1
                fi
                shift 2
                ;;

            --set-target)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}--set-target requires a path.${C_RESET}"; exit 1; }
                FLAG_MODE=true
                mkdir -p "$2"
                TARGET_DIR="$(cd "$2" && pwd)"
                save_config
                echo "  ${C_GREEN}✓ Target set: $TARGET_DIR${C_RESET}"
                shift 2
                ;;

            --set-depth)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}--set-depth requires a number.${C_RESET}"; exit 1; }
                FLAG_MODE=true
                if [[ "$2" =~ ^[0-9]+$ && $2 -gt 0 ]]; then
                    SHORT_PATH_DEPTH="$2"
                    save_config
                    echo "  ${C_GREEN}✓ Short path depth set to $SHORT_PATH_DEPTH${C_RESET}"
                else
                    echo "  ${C_RED}Depth must be a positive integer.${C_RESET}"; exit 1
                fi
                shift 2
                ;;

            # ── Help ─────────────────────────────────────────────────────────
            -h|--help)
                cmd_help_short
                exit 0
                ;;

            --help-full)
                cmd_help_full
                exit 0
                ;;

            # ── Data dir ─────────────────────────────────────────────────
            -D|--data-dir)
                [[ -z "${2:-}" ]] && { echo "  ${C_RED}$1 requires a path.${C_RESET}"; exit 1; }
                MUSICLINK_DATA="$2"; DATA_DIR="$2"
                CONFIG_FILE="${DATA_DIR}/musiclink.conf"
                MANIFEST_FILE="${DATA_DIR}/musiclink.manifest"
                shift 2
                ;;

            *)
                echo "  ${C_RED}Unknown flag: $1${C_RESET}"
                echo ""
                cmd_help_short
                exit 1
                ;;
        esac
    done

    # Execute pending add (so -a and -d can be given in any order)
    if [[ -n "$_PENDING_ADD_SOURCE" ]]; then
        cmd_add "$_PENDING_ADD_SOURCE" "$_PENDING_ADD_DEST"
    fi
}

# ─── Entry point ──────────────────────────────────────────────────────────────
main() {
    # Pre-scan for --data-dir so DATA_DIR is resolved before load_config runs
    local _next_is_datadir=0
    for _arg in "$@"; do
        if (( _next_is_datadir )); then
            MUSICLINK_DATA="$_arg"; DATA_DIR="$_arg"
            CONFIG_FILE="${DATA_DIR}/musiclink.conf"
            MANIFEST_FILE="${DATA_DIR}/musiclink.manifest"
            _next_is_datadir=0
        fi
        [[ "$_arg" == "--data-dir" || "$_arg" == "-D" ]] && _next_is_datadir=1
    done

    load_config
    manifest_init

    if [[ $# -gt 0 ]]; then
        parse_flags "$@"
        # If any flag was processed, we're done
        $FLAG_MODE && exit 0
    fi

    # No flags (or unknown — already exited above) → interactive menu
    main_menu
}

main "$@"
