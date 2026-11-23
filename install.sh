#!/usr/bin/env bash
# install.sh — install / remove the agy-guard launcher.
#
#   ./install.sh [COMMAND] [OPTIONS]
#
# COMMANDS:
#   install (default)     Copy agy-guard into the install dir (see ENV).
#                         A copy, not a symlink, is the default: the guard's
#                         whole purpose is to survive the repo moving or being
#                         deleted along with an accidental CLI reinstall.
#   uninstall | remove | -r
#                         Remove the installed agy-guard (only if it is ours).
#   --help | -h           Show this help.
#   --version             Show the installer + guard version.
#
# OPTIONS:
#   --link                Symlink instead of copying (follows repo edits, but
#                         breaks if the repo moves).
#   --restore             After installing, also (re)write ~/.local/bin/agy from
#                         the guard (`agy-guard restore`) — removes the installer
#                         PATH lines that would shadow it with the raw CLI.
#   --yes | --force       Skip the confirmation prompt before replacing a file
#                         that is not a previous instal of the guard.
#   --dry-run             Print what would change; change nothing.
#
# Environment:
#   AGY_GUARD_INSTALL_DIR   Target directory (default: ~/.local/bin).
#
# Exit codes: 0 success (incl. nothing to do) · 1 runtime error · 2 usage error.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/agy-guard"
LINK_NAME="agy-guard"
GUARD_VERSION="$(sed -n 's/^GUARD_VERSION="\([^"]*\)".*/\1/p' "$SRC" | head -1)"
VERSION="${GUARD_VERSION:-unknown}"

install_dir() { printf '%s' "${AGY_GUARD_INSTALL_DIR:-$HOME/.local/bin}"; }

if [ -t 2 ]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; NC=''
fi
log_info()  { printf '%s\n' "  * $*" >&2; }
log_ok()    { printf '%s\n' "  ${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { printf '%s\n' "  ${YELLOW}WARN:${NC} $*" >&2; }
log_error() { printf '%s\n' "${RED}ERROR:${NC} $*" >&2; }

usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

COMMAND="install"
DRY_RUN=0
FORCE=0
LINK_MODE=0
DO_RESTORE=0

confirm_or_die() {
  local action="$1"
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$FORCE" -eq 1 ] && return 0
  if [ -t 0 ]; then
    local reply
    printf '%s\n' "${YELLOW}?${NC} $action" >&2
    if ! read -r -p "Proceed? [y/N] " reply; then
      echo >&2; log_error "No answer - aborting"; exit 2
    fi
    case "$reply" in [Yy]*) return 0 ;; *) log_warn "Cancelled"; exit 2 ;; esac
  fi
  log_error "$action"
  log_error "Refused: non-interactive run without --yes (use --yes to proceed, --dry-run to preview)"
  exit 2
}

# true when $1 is a previous install of this guard (copy or symlink to it)
is_ours() {
  local target="$1"
  if [ -L "$target" ]; then
    [ "$(readlink -f "$target")" = "$(readlink -f "$SRC")" ] && return 0
    return 1
  fi
  [ -f "$target" ] || return 1
  # compare the launcher body so a stale copy still counts as ours
  local a b
  a=$(sed -n '/^\[ -x "\$REAL" \] || {/,/^exec "\$REAL" "\$@"$/p' "$SRC")
  b=$(sed -n '/^\[ -x "\$REAL" \] || {/,/^exec "\$REAL" "\$@"$/p' "$target")
  [ -n "$a" ] && [ "$a" = "$b" ]
}

do_install() {
  local dir target
  dir="$(install_dir)"; target="$dir/$LINK_NAME"
  [ -f "$SRC" ] || { log_error "guard not found: $SRC"; exit 1; }
  HELPER_SRC="$SRC_DIR/agy-accounts"
  [ -f "$HELPER_SRC" ] || { log_error "accounts helper not found: $HELPER_SRC"; exit 1; }

  ALREADY=0
  if [ -L "$target" ]; then
    if [ "$LINK_MODE" -eq 1 ] && [ "$(readlink -f "$target")" = "$(readlink -f "$SRC")" ]; then
      log_ok "Already installed: $target -> $SRC"; ALREADY=1
    fi
    if [ "$ALREADY" -eq 0 ]; then
      is_ours "$target" && { [ "$LINK_MODE" -eq 0 ] && log_info "Replacing symlink with a copy"; } \
        || confirm_or_die "Replace symlink $target (-> $(readlink "$target")) with the guard from $SRC?"
    fi
  elif [ -f "$target" ]; then
    if [ "$LINK_MODE" -eq 0 ] && cmp -s "$SRC" "$target"; then
      log_ok "Already installed: $target (identical copy)"; ALREADY=1
    elif [ "$LINK_MODE" -eq 1 ] && is_ours "$target"; then
      log_info "Replacing copy with a symlink to $SRC"
    elif ! is_ours "$target"; then
      confirm_or_die "$target exists and is not a previous install of agy-guard; overwrite it?"
    fi
  fi

  if [ "$ALREADY" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      [ -d "$dir" ] || log_info "would: mkdir -p $dir"
      if [ "$LINK_MODE" -eq 1 ]; then
        log_info "would: symlink $target -> $SRC"
      else
        log_info "would: copy $SRC -> $target (chmod 755)"
      fi
      [ "$DO_RESTORE" -eq 1 ] && log_info "would: run $LINK_NAME restore (rewrite ~/.local/bin/agy)"
      log_info "would: install $dir/agy-accounts (accounts helper)"
      return 0
    fi

    [ -d "$dir" ] || mkdir -p "$dir"
    [ -w "$dir" ] || { log_error "$dir is not writable"; exit 1; }

    if [ "$LINK_MODE" -eq 1 ]; then
      local tmp; tmp="$(mktemp -u "$dir/.$LINK_NAME.XXXXXX")"
      ln -s "$SRC" "$tmp"; mv -f "$tmp" "$target"
      log_ok "Linked $target -> $SRC"
      local htmp; htmp="$(mktemp -u "$dir/.agy-accounts.XXXXXX")"
      ln -s "$HELPER_SRC" "$htmp"; mv -f "$htmp" "$dir/agy-accounts"
      log_ok "Linked $dir/agy-accounts -> $HELPER_SRC"
    else
      local tmp; tmp="$(mktemp "$dir/.$LINK_NAME.XXXXXX")"
      cp -f "$SRC" "$tmp"; chmod 755 "$tmp"; mv -f "$tmp" "$target"
      log_ok "Installed $target (copy of $SRC)"
      local htmp; htmp="$(mktemp "$dir/.agy-accounts.XXXXXX")"
      cp -f "$HELPER_SRC" "$htmp"; chmod 755 "$htmp"; mv -f "$htmp" "$dir/agy-accounts"
      log_ok "Installed $dir/agy-accounts (copy of $HELPER_SRC)"
    fi
  else
    # guard already current (ALREADY=1): lay down or update the helper if needed
    local need_helper=0
    if [ ! -e "$dir/agy-accounts" ]; then
      need_helper=1
    elif [ "$LINK_MODE" -eq 1 ]; then
      [ "$(readlink -f "$dir/agy-accounts")" != "$(readlink -f "$HELPER_SRC")" ] && need_helper=1
    elif ! cmp -s "$HELPER_SRC" "$dir/agy-accounts"; then
      need_helper=1
    fi
    if [ "$need_helper" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log_info "would: install $dir/agy-accounts (accounts helper)"
      elif [ "$LINK_MODE" -eq 1 ]; then
        local htmp2; htmp2="$(mktemp -u "$dir/.agy-accounts.XXXXXX")"
        ln -s "$HELPER_SRC" "$htmp2"; mv -f "$htmp2" "$dir/agy-accounts"
        log_ok "Linked $dir/agy-accounts -> $HELPER_SRC"
      else
        local htmp2; htmp2="$(mktemp "$dir/.agy-accounts.XXXXXX")"
        cp -f "$HELPER_SRC" "$htmp2"; chmod 755 "$htmp2"; mv -f "$htmp2" "$dir/agy-accounts"
        log_ok "Installed $dir/agy-accounts (copy of $HELPER_SRC)"
      fi
    fi
  fi

  command -v "$LINK_NAME" >/dev/null 2>&1 && {
    log_ok "$LINK_NAME is on PATH: $(command -v "$LINK_NAME")"
  } || {
    log_info "$LINK_NAME installed at $dir but not on \$PATH."
    log_info "Add to ~/.bashrc:  export PATH=\"\$PATH:$dir\""
  }

  # install receipt so `cli-hub doctor agy-guard` runs `agy-guard doctor --json`
  local receipt_dir="$HOME/.local/share/$LINK_NAME"
  mkdir -p "$receipt_dir" && printf '{"name":"%s","version":"%s","source_dir":"%s","installed_path":"%s","source_hash":"%s","installed_at":"%s"}\n' \
    "$LINK_NAME" "$VERSION" "$SRC_DIR" "$target" \
    "$(sha256sum "$SRC" | cut -c1-12)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$receipt_dir/install-receipt.json" \
    || log_info "could not write install receipt"

  if [ "$DO_RESTORE" -eq 1 ]; then
    log_info "Running '$LINK_NAME restore' …"
    "$target" restore || { log_error "restore failed"; exit 1; }
  else
    local agy="$HOME/.local/bin/agy"
    if [ ! -e "$agy" ]; then
      log_warn "~/.local/bin/agy is missing — run: $LINK_NAME restore"
    elif head -c 4 "$agy" 2>/dev/null | grep -q $'\x7fELF'; then
      log_warn "~/.local/bin/agy is a raw CLI binary (no proxy enforcement) — run: $LINK_NAME restore"
    fi
  fi

  command -v cli-hub >/dev/null 2>&1 && {
    cli-hub register "$LINK_NAME" \
      --version "$VERSION" \
      --description "Fail-closed proxy launcher and repair tool for the Antigravity CLI" \
      --group meta \
      --source-path "$SRC_DIR" \
      --installed-path "$target" \
      --uninstall "$SRC_DIR/install.sh uninstall" \
      --reinstall "$SRC_DIR/install.sh --yes" \
      --yes >/dev/null 2>&1 || log_info "cli-hub register skipped"
  }
  return 0
}

do_uninstall() {
  local dir target
  dir="$(install_dir)"; target="$dir/$LINK_NAME"
  if [ -L "$target" ] || [ -f "$target" ]; then
    if ! is_ours "$target"; then
      log_error "$target is not an install of agy-guard; refusing to remove it"
      exit 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then log_info "would: remove $target"; return 0; fi
    rm -f "$target" "$dir/agy-accounts" || { log_error "failed to remove $target"; exit 1; }
    log_ok "Removed $target (and agy-accounts helper if present)"
    rm -rf "$HOME/.local/share/$LINK_NAME" && log_ok "Removed install receipt"
  else
    log_info "Not found at $target (nothing to do)"
  fi
  command -v cli-hub >/dev/null 2>&1 && \
    { cli-hub unregister "$LINK_NAME" --yes >/dev/null 2>&1 || true; }
  log_info "~/.local/bin/agy (the CLI launcher) was left in place on purpose;
  remove it manually if you really want to lose the proxy guard."
  return 0
}

for arg in "$@"; do
  case "$arg" in
    install|i) COMMAND="install" ;;
    uninstall|remove|rm|--uninstall|-r) COMMAND="uninstall" ;;
    --link) LINK_MODE=1 ;;
    --restore) DO_RESTORE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|--force) FORCE=1 ;;
    --version) printf "install.sh %s (agy-guard %s)\\n" "1.1.0" "$VERSION"; exit 0 ;;
    -h|--help|help) usage; exit 0 ;;
    -*) log_error "Unknown option: $arg"; usage >&2; exit 2 ;;
    *) log_error "Unknown command: $arg"; usage >&2; exit 2 ;;
  esac
done

case "$COMMAND" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
