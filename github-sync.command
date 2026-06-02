#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

REMOTE="${GITHUB_SYNC_REMOTE:-origin}"
BRANCH="${GITHUB_SYNC_BRANCH:-$(git branch --show-current 2>/dev/null || true)}"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '\nPress Enter to close...'
  read -r _ || true
  exit 1
}

run() {
  printf '+ %s\n' "$*"
  "$@"
}

ensure_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "This file must be run inside a Git repository."
  git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "Git remote '$REMOTE' is not configured."
  [[ -n "$BRANCH" ]] || fail "No current Git branch was detected."
}

ensure_upstream() {
  if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    run git branch --set-upstream-to="$REMOTE/$BRANCH" "$BRANCH"
  fi
}

stash_if_needed() {
  if [[ -n "$(git status --porcelain)" ]]; then
    log "Local uncommitted files found. Saving them temporarily before updating."
    run git stash push --include-untracked -m "github-sync temporary stash $(date '+%Y-%m-%d %H:%M:%S')"
    STASHED=1
  else
    STASHED=0
  fi
}

restore_stash_if_needed() {
  if [[ "${STASHED:-0}" == "1" ]]; then
    log "Restoring local uncommitted files."
    if ! git stash pop; then
      fail "GitHub updates were applied, but local changes need manual conflict resolution after 'git stash pop'."
    fi
  fi
}

fetch_remote() {
  log "Checking GitHub for updates."
  run git fetch --prune "$REMOTE"
}

print_comparison() {
  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
  local counts
  counts="$(git rev-list --left-right --count "HEAD...$upstream")"
  local ahead behind
  ahead="${counts%%$'\t'*}"
  behind="${counts##*$'\t'}"

  log "Comparison with $upstream"
  printf 'Local commits not on GitHub: %s\n' "$ahead"
  printf 'GitHub commits not local:    %s\n' "$behind"
}

update_from_github() {
  stash_if_needed

  local upstream counts ahead behind
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
  counts="$(git rev-list --left-right --count "HEAD...$upstream")"
  ahead="${counts%%$'\t'*}"
  behind="${counts##*$'\t'}"

  if [[ "$behind" == "0" ]]; then
    log "Local project is already up to date with GitHub."
  elif [[ "$ahead" == "0" ]]; then
    log "Applying GitHub updates with fast-forward merge."
    run git merge --ff-only "$upstream"
  else
    log "Both local and GitHub have commits. Rebasing local commits on top of GitHub."
    run git rebase "$upstream"
  fi

  restore_stash_if_needed
}

backup_to_github() {
  local upstream counts behind
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
  counts="$(git rev-list --left-right --count "HEAD...$upstream")"
  behind="${counts##*$'\t'}"

  if [[ "$behind" != "0" ]]; then
    fail "GitHub has newer commits. Run './github-sync.command full' before backing up local changes."
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    log "Committing local changes before pushing to GitHub."
    run git add -A
    run git commit -m "Sync local updates $(date '+%Y-%m-%d %H:%M:%S')"
  fi

  log "Pushing local commits to GitHub."
  run git push "$REMOTE" "$BRANCH"
}

main() {
  ensure_repo
  ensure_upstream
  fetch_remote
  print_comparison

  local mode="${1:-}"
  case "$mode" in
    update|pull)
      update_from_github
      ;;
    backup|push)
      backup_to_github
      ;;
    full|sync)
      update_from_github
      backup_to_github
      ;;
    compare|status)
      log "Compare only selected. No files changed."
      ;;
    "")
      choose_from_menu
      ;;
    *)
      fail "Unknown mode: $mode. Use update, backup, full, or compare."
      ;;
  esac

  log "Done."
  git status --short --branch
  printf '\nPress Enter to close...'
  read -r _ || true
}

choose_from_menu() {
  cat <<'MENU'

Choose sync mode:
  1) Update this computer from GitHub
  2) Backup local changes to GitHub
  3) Full sync: update from GitHub, then backup local changes
  4) Compare only

MENU
  printf 'Enter 1, 2, 3, or 4 [1]: '
  read -r choice || true
  choice="${choice:-1}"

  case "$choice" in
    1)
      update_from_github
      ;;
    2)
      backup_to_github
      ;;
    3)
      update_from_github
      backup_to_github
      ;;
    4)
      log "Compare only selected. No files changed."
      ;;
    *)
      fail "Unknown choice: $choice"
      ;;
  esac
}

main "$@"
