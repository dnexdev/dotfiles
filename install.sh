#!/usr/bin/env bash
# usage:
#   ./install.sh             full setup
#   ./install.sh --link      (re)link configs with stow
#   ./install.sh -n          dry run: print what would happen
#   ./install.sh -y          don't ask, answer yes to prompts
#   ./install.sh --no-sudo   (debian/ubuntu) don't use sudo: everything goes in ~/.local
set -euo pipefail
# Error handling: every step that can fail for an ordinary reason is guarded explicitly
# (`|| FAILED+=(...)`) and the run continues to the summary. Don't rely on set -e for that:
# bash ignores it inside any function called from if/!/&&/||. States, invariants and the
# bugs these guards fix: docs/state-machines.md. Must stay bash 3.2-safe (macOS): no
# mapfile/declare -A on shared paths, and guard possibly-empty arrays under set -u.

DOTS="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_PKGS=(zsh starship nvim alacritty)
LINUX_PKGS=(niri dms xdg wallpapers gtk qt fontconfig)
PERSONAL_PKGS=(git ssh) # nex's git identity + ssh host aliases: only when ME=1
# unique per run: two runs in the same second must not share (and restore) each other's backups
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)-$$"
ARCH_RELEASE=${DOTFILES_ARCH_RELEASE:-/etc/arch-release} # (overridable for tests/run.sh)
SNAPSHOT=/usr/local/lib/dotfiles/pkglist-snapshot

DRY=0 YES=0 LINK_ONLY=0 NO_SUDO=0
for arg in "$@"; do
  case $arg in
  -n | --dry-run) DRY=1 ;;
  -y | --yes) YES=1 ;;
  --link) LINK_ONLY=1 ;;
  --no-sudo) NO_SUDO=1 ;;
  -h | --help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
    ;;
  *)
    echo "unknown option: $arg" >&2
    exit 1
    ;;
  esac
done

FAILED=() NOTES=() MOVED=() CREATED=()
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
short_host() { # MagicDNS-style name: macOS says m2.local
  local h
  h=$(uname -n)
  echo "${h%%.*}"
}

[[ $EUID -ne 0 ]] || {
  echo "run as your user, not root" >&2
  exit 1
}

case "$(uname -s)" in
Darwin) OS=mac ;;
Linux)
  OS=linux
  if [[ -f $ARCH_RELEASE ]]; then
    OS=arch
  elif [[ -r /etc/os-release ]] && (. /etc/os-release && [[ $ID == debian || $ID == ubuntu ]]); then
    OS=debian # debian and ubuntu: apt, or ~/.local without sudo
  fi
  ;;
*) OS=other ;;
esac

# debian/ubuntu can run without sudo (debian often has no sudo at all); arch and mac assume it
SUDO=1
if [[ $OS == debian ]]; then
  if ((NO_SUDO)) || ! has sudo; then
    SUDO=0
  elif ! sudo -n true 2>/dev/null && ! id -nG | grep -qwE 'sudo|admin'; then
    SUDO=0
  fi
fi
# Tailscale, Syncthing, sshd and the ssh host shortcuts only work for ME.
# Anyone else gets everything except those.
is_me() {
  local a def=n hint="y/N"
  if [[ $USER == nex ]]; then def=y hint="Y/n"; fi
  if ((YES)); then
    [[ $def == y ]]
    return
  fi
  read -rp "are you nex? and if so, is this a machine you own? [$hint] " a
  [[ ${a:-$def} == [yY]* ]]
}
ME=0
if is_me; then ME=1; else
  NOTES+=("personal setup skipped (git identity, ssh hosts, Tailscale, Syncthing, sshd)")
fi

summary() { # print notes + failures; exit status says whether everything worked
  echo
  say "done"
  for n in ${NOTES[@]+"${NOTES[@]}"}; do echo "  - $n"; done
  if ((${#FAILED[@]})); then
    warn "these didn't work:"
    for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  - $f"; done
    exit 1
  fi
  exit 0
}

# ---------- linking (M3, M4) ----------

move_to_backup() {
  [[ -e $HOME/$1 || -L $HOME/$1 ]] || return 0
  say "backing up ~/$1"
  run mkdir -p "$BACKUP/$(dirname "$1")" && run mv "$HOME/$1" "$BACKUP/$1" || return 1
  if ! ((DRY)); then MOVED+=("$1"); fi
}

# put back exactly what this run moved (files, links, whole dirs, empty dirs), newest
# first, after removing the dirs this run created in their place
restore_backup() {
  local i rel bad=0
  for ((i = ${#CREATED[@]} - 1; i >= 0; i--)); do rmdir "$HOME/${CREATED[i]}" 2>/dev/null || true; done
  for ((i = ${#MOVED[@]} - 1; i >= 0; i--)); do
    rel=${MOVED[i]}
    if [[ -e $HOME/$rel || -L $HOME/$rel ]] || ! mkdir -p "$HOME/$(dirname "$rel")" ||
      ! mv "$BACKUP/$rel" "$HOME/$rel"; then
      warn "couldn't restore ~/$rel (it's still in $BACKUP)"
      bad=1
    fi
  done
  if ((${#MOVED[@]})); then
    if ((bad)); then FAILED+=("restoring backups: some files are still in $BACKUP"); else
      warn "restored your original files"
    fi
  fi
  MOVED=() CREATED=()
}

pkg_files() { (cd "$DOTS/$1" && find . \( -type f -o -type l \) -print | sed 's|^\./||'); }

# foreign_parent PKG: print the first parent dir of PKG's files that is a symlink pointing
# outside the repo (e.g. ~/.config -> /data/config). Stow can't link through it, and moving
# it to the backup would take every other app's config with it, so the package is skipped.
foreign_parent() {
  local rel acc part parts
  while IFS= read -r rel; do
    acc=""
    IFS=/ read -ra parts <<<"$(dirname "$rel")"
    for part in ${parts[@]+"${parts[@]}"}; do
      [[ $part == . ]] && continue
      acc=${acc:+$acc/}$part
      if [[ -L $HOME/$acc && "$(readlink -f "$HOME/$acc")" != "$DOTS/"* ]]; then
        echo "$acc"
        return 0
      fi
    done
  done < <(pkg_files "$1")
  return 1
}

backup_conflicts() { # returns 1 if something couldn't be moved
  local pkg=$1 rel tgt acc part parts
  while IFS= read -r rel; do
    acc=""
    IFS=/ read -ra parts <<<"$(dirname "$rel")"
    for part in ${parts[@]+"${parts[@]}"}; do
      [[ $part == . ]] && continue
      acc=${acc:+$acc/}$part
      if [[ -f $HOME/$acc && ! -L $HOME/$acc ]]; then # a file where a directory must go
        move_to_backup "$acc" || return 1
        break
      fi
    done
    tgt="$HOME/$rel"
    [[ -e $tgt || -L $tgt ]] || continue
    [[ "$(readlink -f "$tgt" 2>/dev/null)" == "$DOTS/$pkg/$rel" ]] && continue
    move_to_backup "$rel" || return 1
  done < <(pkg_files "$pkg")
}

# ensure_dirs PKG: create PKG's top-level dirs in ~ as real dirs, so stow links the files
# inside them instead of folding the whole dir into a symlink to the repo. Runs after
# backup_conflicts, so a *file* in the way has already been moved. ~/.ssh is always a real
# 0700 dir: folded, ssh-keygen would write private keys into the repo.
ensure_dirs() {
  local d
  for d in "$DOTS/$1"/*/ "$DOTS/$1"/.*/; do
    d=$(basename "$d")
    [[ $d == . || $d == .. || $d == '*' || $d == '.*' ]] && continue
    if [[ $d == .ssh && -L $HOME/.ssh && "$(readlink -f "$HOME/.ssh")" == "$DOTS/"* ]]; then
      warn "~/.ssh was a link into the repo; making it a real directory (check ssh/.ssh/ for stray keys)"
      run rm "$HOME/.ssh" || return 1
    fi
    [[ -L $HOME/$d || -d $HOME/$d ]] && continue
    if [[ $d == .ssh ]]; then run mkdir -m 700 "$HOME/$d" || return 1; else
      run mkdir -p "$HOME/$d" || return 1
    fi
    if ! ((DRY)); then CREATED+=("$d"); fi
  done
}

# niri/dms configs + desktop gsettings: always on Arch, elsewhere only once niri is installed
# (on a stock Debian/Ubuntu GNOME they'd just swap in fonts/icons that aren't there)
wants_desktop() {
  case $OS in
  arch) return 0 ;;
  debian | linux) has niri ;;
  *) return 1 ;;
  esac
}

# stand-in for `stow -R` when stow isn't installed (no sudo): links the highest path that
# doesn't exist yet, descends into real directories, same relative links stow makes
link_tree() ( # src dst
  shopt -s dotglob nullglob
  local e t
  for e in "$1"/*; do
    t=$2/${e##*/}
    if [[ -L $t && "$(readlink -f "$t")" == "$(readlink -f "$e")" ]]; then continue; fi
    if [[ -d $t && ! -L $t && -d $e && ! -L $e ]]; then
      link_tree "$e" "$t" || return 1
    elif [[ -e $t || -L $t ]]; then
      warn "conflict: $t"
      return 1
    else
      run ln -s "$(realpath -s --relative-to="$2" "$e")" "$t" || return 1
    fi
  done
)

link_pkgs() {
  if has stow; then
    run stow -d "$DOTS" -t "$HOME" -R "$@"
    return
  fi
  local p
  for p in "$@"; do link_tree "$DOTS/$p" "$HOME" || return 1; done
}

link_configs() {
  local all=("${COMMON_PKGS[@]}") ok=() pkgs=() p bad
  if wants_desktop; then all+=("${LINUX_PKGS[@]}"); fi
  if ((ME)); then all+=("${PERSONAL_PKGS[@]}"); fi
  if ! has stow && ! ((DRY)) && ! has realpath; then # link_pkgs falls back to link_tree
    warn "neither stow nor realpath is installed"
    return 1
  fi
  for p in "${all[@]}"; do
    [[ -d $DOTS/$p ]] || continue
    if bad=$(foreign_parent "$p"); then
      warn "skipped $p: ~/$bad is a symlink outside dotfiles"
      FAILED+=("$p not linked: ~/$bad is a symlink to $(readlink "$HOME/$bad"); link $p's files by hand")
    else ok+=("$p"); fi
  done
  ((${#ok[@]})) || return 0
  say "linking: ${ok[*]}"
  # order matters: move conflicts (incl. a file where a dir goes) first, then create dirs
  for p in "${ok[@]}"; do
    if backup_conflicts "$p" && ensure_dirs "$p"; then pkgs+=("$p"); else
      FAILED+=("$p not linked: couldn't clear or create its directories in ~")
    fi
  done
  if ((${#pkgs[@]})) && ! link_pkgs "${pkgs[@]}"; then
    ((DRY)) || restore_backup
    warn "linking failed: see the conflicts above"
    return 1
  fi
  if [[ -d $HOME/.ssh && ! -L $HOME/.ssh ]]; then run chmod 700 "$HOME/.ssh" || true; fi
  if ((${#MOVED[@]})); then NOTES+=("old configs moved to $BACKUP"); fi
  return 0
}

if ((LINK_ONLY)); then
  link_configs || FAILED+=("linking configs (see the conflicts above)")
  summary
fi

# ---------- Arch packages (M5) ----------

pac_install() {
  (($#)) || return 0
  if ((DRY)); then # the database refresh was only printed, so availability isn't known yet
    run sudo pacman -S --needed --noconfirm "$@"
    return 0
  fi
  local avail=() p
  local -A repo=()
  while IFS= read -r p; do repo[$p]=1; done < <(pacman -Slq)
  for p in "$@"; do
    if [[ -n ${repo[$p]:-} ]]; then avail+=("$p"); else FAILED+=("$p (not in repos)"); fi
  done
  ((${#avail[@]})) || return 0
  sudo pacman -S --needed --noconfirm "${avail[@]}" && return 0
  warn "batch install failed, retrying one at a time"
  for p in "${avail[@]}"; do sudo pacman -S --needed --noconfirm "$p" || FAILED+=("$p"); done
}

aur_install() {
  (($#)) || return 0
  has yay || ((DRY)) || return 0 # yay bootstrap failed: already reported
  run yay -S --needed --noconfirm "$@" && return 0
  warn "AUR batch failed, retrying one at a time"
  local p
  for p in "$@"; do run yay -S --needed --noconfirm "$p" || FAILED+=("$p (aur)"); done
}

gpu_vendor() { grep -qsx "$1" /sys/bus/pci/devices/*/vendor 2>/dev/null; } # 0x10de nvidia, 0x8086 intel

arch_setup() {
  say "base tools"
  # refresh the package databases (and upgrade) first. If that fails, install nothing: after a
  # refresh that worked but an upgrade that didn't, `pacman -S` is a partial upgrade.
  if ! run sudo pacman -Syu --needed --noconfirm git stow base-devel; then
    FAILED+=("system upgrade (sudo pacman -Syu) failed, so no packages were installed; fix it and re-run")
    return 0
  fi

  if ! has yay; then
    say "installing yay"
    if ((DRY)); then
      echo "   [dry] build and install yay-bin from the AUR"
    else
      local tmp
      tmp=$(mktemp -d)
      git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" &&
        (cd "$tmp/yay-bin" && makepkg -si --noconfirm) ||
        FAILED+=("yay (so AUR packages were skipped)")
      rm -rf "$tmp"
    fi
  fi

  # no -debug packages from makepkg
  if grep -qsE '^OPTIONS=.* debug' /etc/makepkg.conf; then
    say "disabling makepkg debug packages"
    run sudo sed -i -E '/^OPTIONS=/s/ debug/ !debug/' /etc/makepkg.conf ||
      FAILED+=("makepkg.conf (set OPTIONS=... !debug by hand)")
  fi

  say "packages (packages/arch.txt)"
  local pkgs=() aur=() p
  while IFS= read -r p; do pkgs+=("$p"); done < <(list "$DOTS/packages/arch.txt")

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
  pac_install ${pkgs[@]+"${pkgs[@]}"}

  say "AUR packages (packages/aur.txt)"
  while IFS= read -r p; do aur+=("$p"); done < <(list "$DOTS/packages/aur.txt")
  aur_install ${aur[@]+"${aur[@]}"}

  if ! pacman -Q dux-shell >/dev/null 2>&1; then
    warn "Dux Shell isn't installed (it comes from Dux's own installer, not the Arch repos)"
    if ask "Run the Dux installer now?"; then
      if ((DRY)); then
        echo "   [dry] curl -fsSL https://install.duxlabs.dev | sh"
      else curl -fsSL https://install.duxlabs.dev | sh || FAILED+=("dux installer"); fi
    fi
  fi
}

# ---------- Arch system (M6, M11) ----------

# pacman hook (M11): runs system/pkglist-snapshot as $USER after each transaction. Root
# only installs the hook + helper into /etc and /usr/local; it never writes into the repo.
pkglist_hook() {
  say "pacman hook: keep pkglist-<host>.txt up to date"
  if [[ $DOTS =~ [^A-Za-z0-9._/-] ]]; then # it's substituted into the hook's Exec line
    FAILED+=("pacman hook: move the repo to a path without spaces or special characters")
    return 0
  fi
  if ((DRY)); then
    echo "   [dry] install system/pkglist-snapshot -> $SNAPSHOT, system/pkglist.hook -> /etc/pacman.d/hooks/"
  else
    local hook
    hook=$(mktemp)
    sed -e "s|@DOTS@|$DOTS|g" -e "s|@USER@|$USER|g" "$DOTS/system/pkglist.hook" >"$hook" &&
      sudo install -Dm755 "$DOTS/system/pkglist-snapshot" "$SNAPSHOT" &&
      sudo install -Dm644 "$hook" /etc/pacman.d/hooks/pkglist.hook ||
      FAILED+=("pacman hook (install system/pkglist.hook by hand)")
    rm -f "$hook"
  fi
  run "$DOTS/system/pkglist-snapshot" "$DOTS" || FAILED+=("package snapshot (pkglist-$(short_host).txt)")
}

arch_system() {
  pkglist_hook
  if pacman -Q zsh >/dev/null 2>&1; then
    run sudo pacman -D --asexplicit zsh >/dev/null || FAILED+=("mark zsh as explicitly installed")
  fi

  say "services"
  if has dms-greeter; then
    # dms-greeter asks for sudo itself and refuses to run under sudo
    run dms-greeter enable -y && run sudo systemctl enable greetd && run dms-greeter sync ||
      FAILED+=("greeter setup (try: dms-greeter enable && dms-greeter sync)")
  fi
  # unlock the login keyring with the greetd password (apps like spotifast store keys there)
  if pacman -Q gnome-keyring >/dev/null 2>&1 && [[ -f /etc/pam.d/greetd ]]; then
    if ! grep -qE '^[[:space:]]*[^#[:space:]].*pam_gnome_keyring' /etc/pam.d/greetd; then
      say "pam: gnome-keyring for greetd"
      run sudo sh -c "printf '%s\n' \
        'auth       optional     pam_gnome_keyring.so' \
        'session    optional     pam_gnome_keyring.so auto_start' >> /etc/pam.d/greetd" ||
        FAILED+=("keyring pam (add pam_gnome_keyring.so auth+session lines to /etc/pam.d/greetd)")
    fi
    run systemctl --user enable gnome-keyring-daemon.socket ||
      FAILED+=("keyring socket (try: systemctl --user enable gnome-keyring-daemon.socket)")
  fi
  if ((ME)) && has tailscale; then
    run sudo systemctl enable --now tailscaled || FAILED+=("tailscaled service")
    tailnet_up # before sshd: its password rule needs this machine's Tailscale address
  fi
  if ((ME)) && has sshd && ask "Accept ssh logins on this machine (keys only, passwords only over Tailscale)?"; then
    sshd_setup
  fi
  if pacman -Q pacman-contrib >/dev/null 2>&1; then
    run sudo systemctl enable --now paccache.timer || FAILED+=("paccache.timer")
  fi
  run sudo systemctl enable --now fstrim.timer || true
}

apt_install() {
  (($#)) || return 0
  local avail=() p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else FAILED+=("$p (not in apt)"); fi
  done
  ((${#avail[@]})) || return 0
  run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${avail[@]}" && return 0
  warn "batch install failed, retrying one at a time"
  for p in "${avail[@]}"; do
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" || FAILED+=("$p")
  done
}

graphical() { [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} || "$(systemctl get-default 2>/dev/null)" == graphical.target ]]; }

# --- user-local installs (~/.local), used when there's no sudo or apt's version won't do ---
LOCAL_BIN="$HOME/.local/bin"

fetch() { # url dest; stock debian/ubuntu desktops have wget but not always curl
  if has curl; then
    curl -fsSL "$1" -o "$2"
  elif has wget; then
    wget -qO "$2" "$1"
  else
    warn "need curl or wget to download $1"
    return 1
  fi
}

latest_tag() { # owner/repo -> tag of its latest release, via the redirect (no API rate limit)
  local u="https://github.com/$1/releases/latest"
  if has curl; then
    curl -fsSLI -o /dev/null -w '%{url_effective}' "$u"
  else
    wget -q --spider -S "$u" 2>&1 | tr -d '\r' | awk '/^ *Location:/ {l = $2} END {print l}'
  fi | sed 's|.*/tag/||'
}

triple() { # rust-style target for this machine
  case $(uname -m) in
  x86_64) echo x86_64-unknown-linux-musl ;;
  aarch64 | arm64) echo aarch64-unknown-linux-musl ;;
  esac
}

goarch() {
  case $(uname -m) in
  x86_64) echo amd64 ;;
  aarch64 | arm64) echo arm64 ;;
  esac
}

# name  repo  asset ({V} = version without the leading v)
RELEASE_TOOLS=(
  "zoxide ajeetdsouza/zoxide zoxide-{V}-$(triple).tar.gz"
  "eza eza-community/eza eza_$(uname -m | sed 's/arm64/aarch64/')-unknown-linux-gnu.tar.gz"
  "rg BurntSushi/ripgrep ripgrep-{V}-$(triple).tar.gz"
  "fd sharkdp/fd fd-v{V}-$(triple).tar.gz"
  "fzf junegunn/fzf fzf-{V}-linux_$(goarch).tar.gz"
  "gh cli/cli gh_{V}_linux_$(goarch).tar.gz"
  "starship starship/starship starship-$(triple).tar.gz"
)

install_release() { # name repo asset-pattern: single binary from a GitHub release tarball
  local name=$1 repo=$2 pat=$3 tag asset tmp bin
  say "$name (github.com/$repo -> ~/.local/bin)"
  if ((DRY)); then
    echo "   [dry] latest $pat"
    return 0
  fi
  tag=$(latest_tag "$repo") && [[ -n $tag && $tag != */* ]] || {
    FAILED+=("$name (couldn't find latest release)")
    return 0
  }
  asset=${pat//\{V\}/${tag#v}}
  tmp=$(mktemp -d)
  if fetch "https://github.com/$repo/releases/download/$tag/$asset" "$tmp/a.tar.gz" &&
    tar -xzf "$tmp/a.tar.gz" -C "$tmp" &&
    bin=$(find "$tmp" -type f -name "$name" | head -n1) && [[ -n $bin ]]; then
    mkdir -p "$LOCAL_BIN" && install -m 755 "$bin" "$LOCAL_BIN/$name" || FAILED+=("$name")
  else
    FAILED+=("$name (download)")
  fi
  rm -rf "$tmp"
}

nvim_ok() { # LazyVim needs 0.11+
  has nvim || return 1
  local v major minor
  v=$(nvim --version | sed -n '1s/^NVIM v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
  read -r major minor <<<"$v"
  ((${major:-0} > 0 || ${minor:-0} >= 11))
}

install_nvim() { # apt's (0.9 on ubuntu 24.04, 0.10 on debian 13) is too old for LazyVim
  nvim_ok && return 0
  local arch url tmp dest="$HOME/.local/opt/nvim"
  case $(uname -m) in
  x86_64) arch=x86_64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    FAILED+=("neovim (no release build for $(uname -m))")
    return 0
    ;;
  esac
  say "neovim (latest release -> ~/.local/opt/nvim)"
  url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$arch.tar.gz"
  if ((DRY)); then
    echo "   [dry] $url"
    return 0
  fi
  tmp=$(mktemp -d)
  if fetch "$url" "$tmp/nvim.tar.gz" && tar -xzf "$tmp/nvim.tar.gz" -C "$tmp"; then
    rm -rf "$dest" && mkdir -p "$(dirname "$dest")" "$LOCAL_BIN" &&
      mv "$tmp/nvim-linux-$arch" "$dest" &&
      ln -sf "$dest/bin/nvim" "$LOCAL_BIN/nvim" || FAILED+=("neovim")
  else
    FAILED+=("neovim (download)")
  fi
  rm -rf "$tmp"
}

install_zsh_local() { # static, relocatable zsh build: github.com/romkatv/zsh-bin
  has zsh && return 0
  say "zsh (zsh-bin -> ~/.local)"
  if ((DRY)); then
    echo "   [dry] romkatv/zsh-bin install -d ~/.local"
    return 0
  fi
  local tmp
  tmp=$(mktemp -d)
  if fetch https://raw.githubusercontent.com/romkatv/zsh-bin/master/install "$tmp/install"; then
    sh "$tmp/install" -q -d "$HOME/.local" -e no || FAILED+=("zsh")
  else
    FAILED+=("zsh (download)")
  fi
  rm -rf "$tmp"
}

install_zsh_plugins() { # same dirs .zshrc looks in
  local name tmp dest
  for name in zsh-autosuggestions zsh-syntax-highlighting; do
    [[ -f /usr/share/$name/$name.zsh || -f /usr/share/zsh/plugins/$name/$name.zsh ]] && continue
    dest="$HOME/.local/share/zsh/plugins/$name"
    [[ -f $dest/$name.zsh ]] && continue
    say "$name -> ~/.local/share/zsh/plugins"
    if ((DRY)); then continue; fi
    tmp=$(mktemp -d)
    if fetch "https://github.com/zsh-users/$name/archive/refs/heads/master.tar.gz" "$tmp/p.tar.gz"; then
      mkdir -p "$dest" && tar -xzf "$tmp/p.tar.gz" -C "$dest" --strip-components=1 || FAILED+=("$name")
    else
      FAILED+=("$name (download)")
    fi
    rm -rf "$tmp"
  done
}

install_nerd_font() {
  local dir="$HOME/.local/share/fonts/JetBrainsMonoNerdFont" tmp
  fc-list 2>/dev/null | grep -q "JetBrainsMono Nerd Font" && return 0
  say "JetBrainsMono Nerd Font -> ~/.local/share/fonts"
  if ((DRY)); then
    echo "   [dry] download nerd-fonts JetBrainsMono.tar.xz"
    return 0
  fi
  tmp=$(mktemp -d)
  if fetch https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz "$tmp/font.tar.xz"; then
    mkdir -p "$dir" && tar -xJf "$tmp/font.tar.xz" -C "$dir" || FAILED+=("JetBrainsMono Nerd Font")
    if has fc-cache; then fc-cache -f "$dir" >/dev/null; fi
  else
    FAILED+=("JetBrainsMono Nerd Font (download)")
  fi
  rm -rf "$tmp"
}

debian_setup() {
  local id ver
  id=$(. /etc/os-release && echo "$ID") ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  [[ $id:$ver == ubuntu:24.04 || $id:$ver == debian:13 ]] ||
    warn "tested on Debian 13 and Ubuntu 24.04, this is $(. /etc/os-release && echo "$PRETTY_NAME")"
  export PATH="$LOCAL_BIN:$PATH" # so `has` sees what we install below

  # in the sudo group isn't proof: check once (may ask for the password), else go user-local
  if ((SUDO && ! DRY)) && ! sudo -n true 2>/dev/null; then
    say "checking sudo (asks for your password)"
    sudo -v || {
      warn "sudo didn't work: installing into ~/.local instead"
      SUDO=0
    }
  fi

  if ((SUDO)); then
    say "packages (packages/apt.txt)"
    run sudo apt-get update || warn "apt-get update failed, using cached package lists"
    mapfile -t pkgs < <(list "$DOTS/packages/apt.txt")
    if [[ $id == debian ]]; then pkgs+=(starship); fi # not packaged on ubuntu 24.04
    if graphical; then pkgs+=(alacritty fonts-inter fontconfig); fi
    apt_install "${pkgs[@]}"
  else
    say "no sudo: installing everything into ~/.local"
  fi

  # whatever apt didn't provide (all of it, without sudo) comes from upstream release builds
  install_zsh_local
  install_zsh_plugins
  local t name repo pat
  for t in "${RELEASE_TOOLS[@]}"; do
    read -r name repo pat <<<"$t"
    if [[ $name == fd ]] && has fdfind; then continue; fi
    has "$name" || install_release "$name" "$repo" "$pat"
  done
  install_nvim
  if graphical; then install_nerd_font; fi

  # debian ships fd as fdfind; LazyVim and muscle memory want fd
  if has fdfind && ! has fd; then
    run mkdir -p "$LOCAL_BIN"
    run ln -sf "$(command -v fdfind)" "$LOCAL_BIN/fd"
  fi

  if ! has git; then FAILED+=("git (needed for nvim plugins: ask an admin for the git package)"); fi
  if ! has cc; then NOTES+=("no C compiler: nvim treesitter parsers won't build (needs build-essential)"); fi
  if graphical && ! has alacritty; then NOTES+=("alacritty needs apt (sudo): configs are linked for when it's there"); fi
  if ! has tailscale && ((SUDO)); then
    NOTES+=("tailscale isn't installed: curl -fsSL https://tailscale.com/install.sh | sh")
  fi
}

tailnet_up() { # log in to Tailscale if this machine isn't on the tailnet yet (Linux)
  [[ $OS != mac ]] && has tailscale || return 0
  tailscale status >/dev/null 2>&1 && return 0
  if ((!SUDO)); then
    NOTES+=("not on the tailnet: tailscale up needs root (ask an admin)")
    return 0
  fi
  say "joining the tailnet (open the link it prints)"
  run sudo tailscale up || FAILED+=("tailscale (run: sudo tailscale up)")
}

# sshd (M6): keys only. Passwords only for connections that arrive AT this machine's
# Tailscale IPv4 address FROM a Tailscale address; see system/sshd.conf for why both
# halves are needed and why IPv6 is left out. Installed as a transaction: if the new
# config is rejected, the previous drop-in is put back and sshd is not reloaded.
sshd_setup() {
  say "sshd"
  local dest=/etc/ssh/sshd_config.d/10-dotfiles.conf conf prev ip4 had=0
  ip4=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if ((DRY)); then
    echo "   [dry] install system/sshd.conf${ip4:+ + passwords at $ip4 from the tailnet} -> $dest, enable sshd"
    return 0
  fi
  conf=$(mktemp)
  prev=$(mktemp)
  cat "$DOTS/system/sshd.conf" >"$conf"
  if [[ -n $ip4 ]]; then
    printf '\n# added by install.sh: passwords only from the tailnet, to the Tailscale address\nMatch LocalAddress %s Address 100.64.0.0/10,!100.115.92.0/23\n    PasswordAuthentication yes\nMatch all\n' \
      "$ip4" >>"$conf"
  else
    NOTES+=("ssh passwords stay off until Tailscale is up; then re-run install.sh")
  fi
  if sudo test -f "$dest" && sudo cat "$dest" >"$prev"; then had=1; fi
  if sudo install -Dm644 "$conf" "$dest" && sudo sshd -t; then
    sudo systemctl enable --now sshd && sudo systemctl reload sshd || FAILED+=("sshd service")
  else
    local back=0
    if ((had)); then sudo install -m644 "$prev" "$dest" && back=1; else sudo rm -f "$dest" && back=1; fi
    if ((back)) && sudo sshd -t; then
      FAILED+=("sshd config rejected by sshd -t; the previous one is still in place")
    else
      FAILED+=("sshd config rejected AND rollback failed: fix $dest before restarting sshd")
    fi
  fi
  rm -f "$conf" "$prev"
}

# ---------- macOS ----------

mac_setup() {
  if ! has brew; then
    ask "Homebrew isn't installed. Install it?" || {
      warn "skipping packages"
      return 0
    }
    if ((DRY)); then
      echo "   [dry] install homebrew"
    else
      # download first: `bash -c "$(curl ...)"` runs an empty script when curl fails
      local inst
      inst=$(mktemp)
      curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$inst" &&
        /bin/bash "$inst" || FAILED+=("homebrew install")
      rm -f "$inst"
      if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
      has brew || {
        FAILED+=("homebrew isn't available, so no packages were installed")
        return 0
      }
    fi
  fi
  say "packages (Brewfile)"
  run brew bundle --file "$DOTS/Brewfile" || FAILED+=("some Brewfile entries")
  if ((ME)); then NOTES+=("open the Tailscale app and sign in"); fi
}

# ---------- personal: Syncthing (M8), git (M7), Legion (M10) ----------

sync_setup() { # Syncthing (M8): same folders, same folder IDs on every machine
  has syncthing || {
    warn "syncthing not installed, skipping file sync"
    return 0
  }
  local ids=() paths=() out id rel i
  if ! out=$("$DOTS/syncthing/pair.sh" --folders); then # the one parser for syncthing/folders
    FAILED+=("syncthing/folders has a bad entry")
    return 0
  fi
  while read -r id rel; do
    [[ -n $id ]] || continue
    ids+=("$id")
    if [[ $rel == . ]]; then paths+=("$HOME"); else paths+=("$HOME/$rel"); fi
  done <<<"$out"
  ((${#ids[@]})) || return 0
  say "syncthing (${ids[*]})"
  if [[ $OS == mac ]]; then
    run brew services start syncthing || FAILED+=("syncthing (try: brew services start syncthing)")
  else
    run systemctl --user enable --now syncthing.service ||
      FAILED+=("syncthing (try: systemctl --user enable --now syncthing)")
    # keep user services (syncthing) running with nobody logged in, e.g. a box you only ssh into
    if ((SUDO)); then run sudo loginctl enable-linger "$USER" || true; fi
  fi
  local dir ign
  for ((i = 0; i < ${#ids[@]}; i++)); do
    dir=${paths[i]} ign=${paths[i]}/.stignore
    if ! run mkdir -p "$dir"; then
      FAILED+=("$dir (couldn't create it)")
    elif [[ -e $ign && ! -L $ign ]]; then
      warn "$ign exists and isn't from dotfiles, leaving it (compare with syncthing/stignore)"
    else
      run ln -sfn "$DOTS/syncthing/stignore" "$ign" || FAILED+=("$ign link")
    fi
  done
  if ((DRY)); then
    echo "   [dry] add syncthing folders: ${ids[*]} (30-day versioning)"
    return 0
  fi
  for i in {1..30}; do # wait for the daemon's API
    syncthing cli show system >/dev/null 2>&1 && break
    sleep 1
  done
  local have st other opath
  if ! have=$(syncthing cli config folders list 2>/dev/null); then
    FAILED+=("syncthing isn't responding, so no folders were added (re-run later)")
    return 0
  fi
  for ((i = 0; i < ${#ids[@]}; i++)); do
    id=${ids[i]} dir=${paths[i]}
    # an existing folder inside this one (e.g. code, before the whole home was synced) would
    # nest: drop it from Syncthing's config. Its files stay; the outer folder now covers them.
    while IFS= read -r other; do
      [[ -n $other && $other != "$id" ]] || continue
      opath=$(syncthing cli config folders "$other" path get 2>/dev/null) || continue
      opath=${opath%/}
      if [[ $opath == "$dir"/* || $dir == "$opath"/* || $opath == "$dir" ]]; then
        say "syncthing: folder '$other' ($opath) overlaps '$id': removing it from the config (files are kept)"
        syncthing cli config folders "$other" delete || FAILED+=("syncthing: remove overlapping folder '$other' in the web UI")
      fi
    done <<<"$have"
    if ! grep -qxF -- "$id" <<<"$have"; then
      syncthing cli config folders add --id "$id" --label "$id" --path "$dir" || {
        FAILED+=("syncthing folder $id")
        continue
      }
    fi
    # versioning: a file deleted or overwritten by the other machine is kept for 30 days in
    # <folder>/.stversions instead of being gone. Left alone if you chose another kind.
    st=$(syncthing cli config folders "$id" versioning type get 2>/dev/null || true)
    if [[ -z $st ]]; then
      syncthing cli config folders "$id" versioning type set trashcan &&
        syncthing cli config folders "$id" versioning params set cleanoutDays 30 ||
        FAILED+=("syncthing versioning for $id (set it in the web UI)")
    fi
  done
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
  # chsh only takes shells listed in /etc/shells, and adding one there needs sudo
  if ! grep -qx "$zsh" /etc/shells 2>/dev/null; then
    if ((SUDO)); then
      run sudo sh -c "echo '$zsh' >> /etc/shells" || {
        FAILED+=("login shell (add $zsh to /etc/shells, then: chsh -s $zsh)")
        return 0
      }
    else
      bash_to_zsh "$zsh"
      return 0
    fi
  fi
  say "default shell -> zsh (asks for your password)"
  run chsh -s "$zsh" && return 0
  if [[ $OS == debian ]]; then bash_to_zsh "$zsh"; else FAILED+=("login shell (run: chsh -s $zsh)"); fi
}

bash_to_zsh() { # can't change the login shell: have interactive bash hand over to zsh instead
  local rc="$HOME/.bashrc" mark="# dotfiles: start zsh"
  grep -qsF "$mark" "$rc" && return 0
  say "can't change login shell: ~/.bashrc will start zsh"
  if ((DRY)); then
    echo "   [dry] append zsh handoff to ~/.bashrc"
    return 0
  fi
  # skipped when zsh is the parent, so typing `bash` in zsh still gives you bash
  printf '\n%s\nif [[ $- == *i* && -x %q && "$(cat /proc/$PPID/comm 2>/dev/null)" != zsh ]]; then\n  SHELL=%q exec %q -l\nfi\n' \
    "$mark" "$1" "$1" "$1" >>"$rc"
  NOTES+=("~/.bashrc now hands interactive shells to zsh (login shell is still bash)")
}

ssh_dir_in_repo() { # does ~/.ssh resolve into the repo? (then keys would land in git)
  local r
  r=$(cd -P "$HOME/.ssh" 2>/dev/null && pwd) || return 1
  [[ $r == "$DOTS" || $r == "$DOTS/"* ]]
}

git_setup() {
  local key="$HOME/.ssh/id_ed25519" email
  email=$(git config --global user.email || echo "me@dnex.dev")
  if ssh_dir_in_repo; then
    FAILED+=("~/.ssh points into the dotfiles repo: refusing to write keys there (run ./install.sh --link)")
    return 0
  fi
  if [[ ! -f $key.pub ]] && ask "No SSH key found. Create one (for GitHub + commit signing)?"; then
    if [[ -d $HOME/.ssh ]] || run mkdir -m 700 "$HOME/.ssh"; then
      if run ssh-keygen -t ed25519 -C "$email" -f "$key"; then
        NOTES+=("add ~/.ssh/id_ed25519.pub to GitHub as BOTH an Authentication and a Signing key")
      else FAILED+=("ssh key (run: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519)"); fi
    else FAILED+=("~/.ssh (couldn't create it)"); fi
  fi
  # only touch the keys we own: anything else in ~/.gitconfig.local or allowed_signers
  # (other machines' signing keys, includeIf, aliases) is kept
  say "writing ~/.gitconfig.local"
  if ((DRY)); then
    echo "   [dry] signing config for $key.pub"
    return 0
  fi
  local cfg=(git config --file "$HOME/.gitconfig.local") signers=$HOME/.ssh/allowed_signers line
  if [[ -f $key.pub ]]; then
    line="$email $(cat "$key.pub")"
    "${cfg[@]}" user.signingkey "$key.pub" &&
      "${cfg[@]}" gpg.ssh.allowedSignersFile "$signers" &&
      { "${cfg[@]}" --unset commit.gpgsign || [[ $? == 5 ]]; } && # 5: wasn't set
      { grep -qxF -- "$line" "$signers" 2>/dev/null || echo "$line" >>"$signers"; } ||
      FAILED+=("git signing config (~/.gitconfig.local / ~/.ssh/allowed_signers)")
  else
    "${cfg[@]}" commit.gpgsign false || FAILED+=("git config (~/.gitconfig.local)")
    NOTES+=("commit signing is off until you create an SSH key and re-run ./install.sh")
  fi
}

# Legion (M10). States: batch-ok -> interactive-ok -> key copied + verified -> unreachable.
# A failed BatchMode probe only means "no unlocked key": it isn't treated as unreachable.
connect_setup() {                       # hook this machine up to the Legion (ssh alias: us)
  tailnet_up                            # no-op on Arch (arch_system did it) and macOS (the app does it)
  [[ $(short_host) == us ]] && return 0 # this is the Legion
  local pair=("$DOTS/syncthing/pair.sh" us)
  if ((DRY)); then
    echo "   [dry] check ssh us (ssh-copy-id us if needed)"
    echo "   [dry] ${pair[*]}"
    return 0
  fi
  probe() { ssh -o ConnectTimeout=5 -o PreferredAuthentications=publickey "$@" us true; }
  local ok=0
  if probe -o BatchMode=yes 2>/dev/null; then
    ok=1
  else
    say "checking ssh to the Legion (may ask for your key's passphrase)"
    if probe; then
      ok=1
    elif [[ -f $HOME/.ssh/id_ed25519.pub ]] && ask "Copy your ssh key to the Legion (asks for its password once)?"; then
      say "ssh-copy-id us"
      if ssh-copy-id -o ConnectTimeout=5 us && probe; then ok=1; fi
    fi
  fi
  if ((! ok)); then
    FAILED+=("Legion (us) not reachable over ssh; when it is: ssh-copy-id us && ${pair[*]}")
  elif has syncthing && ask "Pair Syncthing with the Legion?"; then
    "${pair[@]}" || FAILED+=("syncthing pairing (run: ${pair[*]})")
  fi
}

desktop_settings() { # gsettings that GTK/portals read on wayland (fonts, icons, cursor)
  has gsettings || return 0
  say "desktop settings (fonts, icons, cursor)"
  local gs=(gsettings)
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || gs=(dbus-run-session -- gsettings) # from a tty
  local kv k v
  for kv in \
    "font-name=Inter 11" \
    "monospace-font-name=JetBrainsMono Nerd Font 11" \
    "icon-theme=kora" \
    "cursor-theme=Adwaita" \
    "cursor-size=24" \
    "color-scheme=prefer-dark" \
    "text-scaling-factor=1.0" \
    "font-antialiasing=grayscale" \
    "font-hinting=slight"; do
    k=${kv%%=*} v=${kv#*=}
    [[ $v =~ ^[0-9.]+$ ]] || v="'$v'"
    run "${gs[@]}" set org.gnome.desktop.interface "$k" "$v" || FAILED+=("gsettings $k")
  done
}

# ---------- main (M2) ----------

if ((DRY)); then say "DRY RUN: nothing will change"; fi
case $OS in
arch) arch_setup ;;
debian) debian_setup ;;
mac) mac_setup ;;
*) warn "unsupported OS ($OS): only linking configs" ;;
esac
link_configs || FAILED+=("linking configs (fix the conflicts above, then: ./install.sh --link)")
shell_setup
if ((ME)); then sync_setup; fi
if wants_desktop; then desktop_settings; fi
if [[ $OS == arch ]]; then
  arch_system
  NOTES+=("reboot (or log out) to land in the greeter")
fi
if ((ME)); then
  git_setup
  connect_setup
fi
summary
