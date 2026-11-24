#!/usr/bin/env bash
# usage:
#   ./install.sh             full setup
#   ./install.sh --link      (re)link configs with stow
#   ./install.sh -n          dry run: print what would happen
#   ./install.sh -y          don't ask, answer yes to prompts
#   ./install.sh --no-sudo   (debian/ubuntu) don't use sudo: everything goes in ~/.local
set -euo pipefail

DOTS="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_PKGS=(zsh starship nvim git alacritty)
LINUX_PKGS=(niri dms xdg wallpapers gtk qt fontconfig)
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

DRY=0 YES=0 LINK_ONLY=0 NO_SUDO=0
for arg in "$@"; do
  case $arg in
  -n | --dry-run) DRY=1 ;;
  -y | --yes) YES=1 ;;
  --link) LINK_ONLY=1 ;;
  --no-sudo) NO_SUDO=1 ;;
  -h | --help)
    sed -n '2,9p' "$0"
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
Linux)
  OS=linux
  if [[ -f /etc/arch-release ]]; then
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
  local pkgs=("${COMMON_PKGS[@]}") p
  if wants_desktop; then pkgs+=("${LINUX_PKGS[@]}"); fi
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
  if ! link_pkgs "${pkgs[@]}"; then
    ((DRY)) || restore_backup
    warn "linking failed: see the conflicts above"
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
  if has tailscale; then run sudo systemctl enable --now tailscaled; fi
  if pacman -Q pacman-contrib >/dev/null 2>&1; then run sudo systemctl enable --now paccache.timer; fi
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
  if ((SUDO && !DRY)) && ! sudo -n true 2>/dev/null; then
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
  # chsh only takes shells listed in /etc/shells, and adding one there needs sudo
  if ! grep -qx "$zsh" /etc/shells 2>/dev/null; then
    if ((SUDO)); then
      run sudo sh -c "echo '$zsh' >> /etc/shells"
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

if ((DRY)); then say "DRY RUN: nothing will change"; fi
case $OS in
arch) arch_setup ;;
debian) debian_setup ;;
mac) mac_setup ;;
*) warn "unsupported OS ($OS): only linking configs" ;;
esac
link_configs
shell_setup
if wants_desktop; then desktop_settings; fi
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
