#!/usr/bin/env bash
# warden4w dotfiles installer — idempotent, symlink-based, backs up what it replaces.
set -euo pipefail

# Resolve the repo root (dir this script lives in), regardless of where it's called from.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# link SRC -> DEST: back up a pre-existing real file/dir, then symlink.
link() {
  local src="$1" dest="$2"
  if [[ ! -e "$src" ]]; then
    echo "skip: $src missing in repo"; return
  fi
  # Already the correct symlink? Nothing to do.
  if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
    echo "ok:   $dest already linked"; return
  fi
  # Back up anything real (or a wrong symlink) that's in the way.
  if [[ -e "$dest" || -L "$dest" ]]; then
    mv "$dest" "${dest}.warden-bak.${STAMP}"
    echo "bak:  $dest -> ${dest}.warden-bak.${STAMP}"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  echo "link: $dest -> $src"
}

# --- zsh ---
link "$REPO/zsh/zshrc" "$HOME/.zshrc"

# --- nvim overrides (LazyVim base stays baked in the image) ---
# Link only the override subdirs so we don't clobber the baked ~/.config/nvim.
if [[ -d "$REPO/nvim/lua/config" ]]; then
  for f in "$REPO"/nvim/lua/config/*; do
    [[ -e "$f" ]] && link "$f" "$HOME/.config/nvim/lua/config/$(basename "$f")"
  done
fi
if [[ -d "$REPO/nvim/lua/plugins" ]]; then
  for f in "$REPO"/nvim/lua/plugins/*; do
    [[ -e "$f" ]] && link "$f" "$HOME/.config/nvim/lua/plugins/$(basename "$f")"
  done
fi

echo "warden4w dotfiles installed."
