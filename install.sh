#!/usr/bin/env bash
# usage:
#   ./install.sh             full setup
#   ./install.sh --link      (re)link configs with stow
#   ./install.sh -n          dry run: print what would happen
#   ./install.sh -y          don't ask, answer yes to prompts
set -euo pipefail

DOTS="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_PKGS=(zsh starship nvim git alacritty)
LINUX_PKGS=(niri dms xdg wallpapers)
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

DRY=0 YES=0 LINK_ONLY=0
for arg in "$@"; do
  case $arg in
  -n | --dry-run) DRY=1 ;;
  -y | --yes) YES=1 ;;
  --link) LINK_ONLY=1 ;;
  -h | --help)
    sed -n '2,8p' "$0"
    exit 0
    ;;
  *)
    echo "unknown option: $arg" >&2
    exit 1
    ;;
  esac
done

FAILED=() NOTES=()
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
run() { if ((DRY)); then printf '   [dry] %s\n' "$*"; else "$@"; fi; }
ask() {
  ((YES)) && return 0
  local a
  read -rp "$1 [Y/n] " a
  case $a in [nN]*) return 1 ;; esac
}
has() { command -v "$1" >/dev/null 2>&1; }
list() { # strip comments/blanks; warn instead of failing if the file is missing
  [[ -f $1 ]] || {
    warn "missing ${1#"$DOTS"/}, skipping"
    return 0
  }
  grep -vE '^[[:space:]]*(#|$)' "$1" | awk '{print $1}'
}

[[ $EUID -ne 0 ]] || {
  echo "run as your user, not root" >&2
  exit 1
}

case "$(uname -s)" in
Darwin) OS=mac ;;
Linux) [[ -f /etc/arch-release ]] && OS=arch || OS=linux ;;
*) OS=other ;;
esac

move_to_backup() {
  [[ -e $HOME/$1 || -L $HOME/$1 ]] || return 0
  say "backing up ~/$1"
  run mkdir -p "$BACKUP/$(dirname "$1")"
  run mv "$HOME/$1" "$BACKUP/$1"
}

backup_conflicts() {
  local pkg=$1 rel tgt acc part parts
  while IFS= read -r rel; do
    rel=${rel#./}
    acc=""
    IFS=/ read -ra parts <<<"$(dirname "$rel")"
    for part in "${parts[@]}"; do
      [[ $part == . ]] && continue
      acc=${acc:+$acc/}$part
      if [[ -L $HOME/$acc && "$(readlink -f "$HOME/$acc")" != "$DOTS/"* ]] || [[ -f $HOME/$acc ]]; then
        move_to_backup "$acc"
        break
      fi
    done
    tgt="$HOME/$rel"
    [[ -e $tgt || -L $tgt ]] || continue
    [[ "$(readlink -f "$tgt" 2>/dev/null)" == "$DOTS/$pkg/$rel" ]] && continue
    move_to_backup "$rel"
  done < <(cd "$DOTS/$pkg" && find . \( -type f -o -type l \) -print)
}

restore_backup() {
  [[ -d $BACKUP ]] || return 0
  local rel
  while IFS= read -r rel; do
    rel=${rel#./}
    mkdir -p "$HOME/$(dirname "$rel")"
    mv "$BACKUP/$rel" "$HOME/$rel"
  done < <(cd "$BACKUP" && find . \( -type f -o -type l \) -print)
  warn "restored your original files"
}

link_configs() {
  local pkgs=("${COMMON_PKGS[@]}") p
  if [[ $OS == arch || $OS == linux ]]; then pkgs+=("${LINUX_PKGS[@]}"); fi
  has stow || {
    warn "stow not installed"
    return 1
  }
  say "linking: ${pkgs[*]}"
  local d
  for p in "${pkgs[@]}"; do
    [[ -d $DOTS/$p ]] || continue
    for d in "$DOTS/$p"/*/ "$DOTS/$p"/.*/; do
      d=$(basename "$d")
      [[ $d == . || $d == .. || $d == '*' || $d == '.*' ]] && continue
      [[ -L $HOME/$d || -d $HOME/$d ]] || run mkdir -p "$HOME/$d"
    done
  done
  for p in "${pkgs[@]}"; do if [[ -d $DOTS/$p ]]; then backup_conflicts "$p"; fi; done
  if ! run stow -d "$DOTS" -t "$HOME" -R "${pkgs[@]}"; then
    ((DRY)) || restore_backup
    warn "stow failed: see the conflicts above"
    return 1
  fi
  if [[ -d $BACKUP ]]; then NOTES+=("old configs moved to $BACKUP"); fi
  return 0
}

if ((LINK_ONLY)); then
  link_configs
  exit 0
fi

pac_install() {
  (($#)) || return 0
  local avail=() p
  local -A repo=()
  while IFS= read -r p; do repo[$p]=1; done < <(pacman -Slq)
  for p in "$@"; do
    if [[ -n ${repo[$p]:-} ]]; then avail+=("$p"); else FAILED+=("$p (not in repos)"); fi
  done
  ((${#avail[@]})) || return 0
  run sudo pacman -S --needed --noconfirm "${avail[@]}" && return 0
  warn "batch install failed, retrying one at a time"
  for p in "${avail[@]}"; do run sudo pacman -S --needed --noconfirm "$p" || FAILED+=("$p"); done
}

aur_install() {
  (($#)) || return 0
  run yay -S --needed --noconfirm "$@" && return 0
  warn "AUR batch failed, retrying one at a time"
  local p
  for p in "$@"; do run yay -S --needed --noconfirm "$p" || FAILED+=("$p (aur)"); done
}

gpu_vendor() { grep -qsx "$1" /sys/bus/pci/devices/*/vendor 2>/dev/null; } # 0x10de nvidia, 0x8086 intel

arch_setup() {
  say "base tools"
  run sudo pacman -S --needed --noconfirm git stow base-devel

  if ! has yay; then
    say "installing yay"
    local tmp
    tmp=$(mktemp -d)
    run git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
    (cd "$tmp/yay-bin" && run makepkg -si --noconfirm)
    rm -rf "$tmp"
  fi

  # no -debug packages from makepkg
  if grep -qsE '^OPTIONS=.* debug' /etc/makepkg.conf; then
    say "disabling makepkg debug packages"
    run sudo sed -i -E '/^OPTIONS=/s/ debug/ !debug/' /etc/makepkg.conf
  fi

  say "packages (packages/arch.txt)"
  mapfile -t pkgs < <(list "$DOTS/packages/arch.txt")

  if [[ $(uname -m) == x86_64 ]]; then
    if gpu_vendor 0x10de; then
      say "NVIDIA GPU detected"
      pkgs+=(nvidia-open-dkms nvidia-utils)
      if pacman -Slq multilib >/dev/null 2>&1; then pkgs+=(lib32-nvidia-utils); fi
      local k
      for k in linux linux-lts linux-zen; do
        if pacman -Q "$k" >/dev/null 2>&1; then pkgs+=("$k-headers"); fi
      done
    fi
    if gpu_vendor 0x8086; then pkgs+=(intel-media-driver vulkan-intel); fi
  fi
  pac_install "${pkgs[@]}"

  say "AUR packages (packages/aur.txt)"
  mapfile -t aur < <(list "$DOTS/packages/aur.txt")
  aur_install "${aur[@]}"

  if ! pacman -Q dux-shell >/dev/null 2>&1; then
    warn "Dux Shell isn't installed (it comes from Dux's own installer, not the Arch repos)"
    if ask "Run the Dux installer now?"; then
      if ((DRY)); then
        echo "   [dry] curl -fsSL https://install.duxlabs.dev | sh"
      else curl -fsSL https://install.duxlabs.dev | sh || FAILED+=("dux installer"); fi
    fi
  fi
}

arch_system() {
  say "pacman hook: keep pkglist-<host>.txt up to date"
  run sudo mkdir -p /etc/pacman.d/hooks
  run sudo rm -f /etc/pacman.d/hooks/pkglist.hook # never write through an old symlink
  if ((DRY)); then
    echo "   [dry] render system/pkglist.hook -> /etc/pacman.d/hooks/"
  else sed -e "s|@DOTS@|$DOTS|g" -e "s|@USER@|$USER|g" "$DOTS/system/pkglist.hook" |
    sudo tee /etc/pacman.d/hooks/pkglist.hook >/dev/null; fi
  local h
  h=$(uname -n)
  run sh -c "pacman -Qqen > '$DOTS/pkglist-$h.txt'; pacman -Qqem > '$DOTS/aur-$h.txt'"
  if pacman -Q zsh >/dev/null 2>&1; then run sudo pacman -D --asexplicit zsh >/dev/null; fi

  say "services"
  if has dms-greeter; then
    # dms-greeter asks for sudo itself and refuses to run under sudo
    run dms-greeter enable -y && run sudo systemctl enable greetd && run dms-greeter sync ||
      FAILED+=("greeter setup (try: dms-greeter enable && dms-greeter sync)")
  fi
  if has tailscale; then run sudo systemctl enable --now tailscaled; fi
  if pacman -Q pacman-contrib >/dev/null 2>&1; then run sudo systemctl enable --now paccache.timer; fi
  run sudo systemctl enable --now fstrim.timer || true
}

mac_setup() {
  if ! has brew; then
    ask "Homebrew isn't installed. Install it?" || {
      warn "skipping packages"
      return 0
    }
    if ((DRY)); then
      echo "   [dry] install homebrew"
    else
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi
  say "packages (Brewfile)"
  run brew bundle --file "$DOTS/Brewfile" || FAILED+=("some Brewfile entries")
}

login_shell() { # what's actually set, not $SHELL (that only updates after re-login)
  if [[ $OS == mac ]]; then
    dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$USER" | cut -d: -f7
  fi
}

shell_setup() {
  local zsh
  zsh=$(command -v zsh || true)
  [[ -n $zsh && "$(login_shell)" != */zsh ]] || return 0
  say "default shell -> zsh (asks for your password)"
  grep -qx "$zsh" /etc/shells || run sudo sh -c "echo '$zsh' >> /etc/shells"
  run chsh -s "$zsh" || FAILED+=("login shell (run: chsh -s $zsh)")
}

git_setup() {
  local key="$HOME/.ssh/id_ed25519" email
  email=$(git config --global user.email || echo "me@dnex.dev")
  if [[ ! -f $key.pub ]] && ask "No SSH key found. Create one (for GitHub + commit signing)?"; then
    run mkdir -p "$HOME/.ssh"
    run ssh-keygen -t ed25519 -C "$email" -f "$key"
    NOTES+=("add ~/.ssh/id_ed25519.pub to GitHub as BOTH an Authentication and a Signing key")
  fi
  say "writing ~/.gitconfig.local"
  if ((DRY)); then
    echo "   [dry] signing config for $key.pub"
    return 0
  fi
  if [[ -f $key.pub ]]; then
    printf '[user]\n\tsigningkey = %s\n[gpg "ssh"]\n\tallowedSignersFile = %s\n' \
      "$key.pub" "$HOME/.ssh/allowed_signers" >"$HOME/.gitconfig.local"
    echo "$email $(cat "$key.pub")" >"$HOME/.ssh/allowed_signers"
  else
    printf '[commit]\n\tgpgsign = false\n' >"$HOME/.gitconfig.local"
    NOTES+=("commit signing is off until you create an SSH key and re-run ./install.sh")
  fi
}

if ((DRY)); then say "DRY RUN: nothing will change"; fi
case $OS in
arch) arch_setup ;;
mac) mac_setup ;;
*) warn "unsupported OS ($OS): only linking configs" ;;
esac
link_configs
shell_setup
if [[ $OS == arch ]]; then
  arch_system
  NOTES+=("reboot (or log out) to land in the greeter")
fi
git_setup

echo
say "done"
for n in ${NOTES[@]+"${NOTES[@]}"}; do echo "  - $n"; done
if ((${#FAILED[@]})); then
  warn "these didn't install:"
  for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  - $f"; done
fi
exit 0
