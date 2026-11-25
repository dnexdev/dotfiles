#!/usr/bin/env bash
# Regression tests for install.sh, syncthing/pair.sh and system/pkglist-snapshot.
# Test names carry the bug IDs from docs/state-machines.md: B<n> (first pass), R<n> (second
# review) and S<n> (Syncthing whole-home sync).
#
# Hermetic: every test copies the repo to a temp dir, gets a fake $HOME, and runs with a
# PATH that holds only stubs plus a whitelist of harmless real tools. Stubs log every call
# to $STUBROOT/log and never touch the real system (sudo, pacman, systemctl, ssh, ...).
# "Root" files that sudo would touch live under $STUBROOT/root; Syncthing's config is a
# small fake store under $STUBROOT/st/<local|remote>.
#
# usage: tests/run.sh [substring to select tests]
# needs: bash, git, tar, perl + stow; sshd for the B1 tests (skipped without it)
set -uo pipefail

REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILTER=${1:-}
PASSED=0 SKIPPED=0 FAILED=()
ESC=$(printf '\033')
SSHD=$(command -v sshd || ls /usr/sbin/sshd 2>/dev/null || true)

REAL=(bash sh env cat cp mv rm ln mkdir rmdir chmod readlink realpath basename dirname find
  grep sed awk cut tr sort head tail tee mktemp date sleep touch wc perl stow diff git seq
  paste id)
STUBS=(uname sudo pacman yay makepkg curl systemctl loginctl chsh getent ssh ssh-copy-id
  ssh-keygen tailscale syncthing sshd dscl)

# ---------- fixture ----------

setup() {
  T=$(mktemp -d)
  export STUBROOT=$T
  mkdir -p "$T/home" "$T/bin" "$T/sys" "$T/behave" "$T/tmp" "$T/installed" "$T/root"
  touch "$T/arch-release"
  (cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) |
    (mkdir -p "$T/dots" && cd "$T/dots" && tar -xf -)
  local t p
  for t in "${REAL[@]}"; do
    if p=$(command -v "$t"); then ln -s "$p" "$T/sys/$t"; fi
  done
  for t in "${STUBS[@]}"; do stub "$t"; done
  # most tests predate the whole-home folder: give them a plain list unless they set one
  printf 'code\nnotes\nDocuments\n' >"$T/dots/syncthing/folders"

  behave uname <<'EOF'
case $1 in
-s) echo "${FAKE_UNAME_S:-Linux}" ;;
-m) echo "${FAKE_UNAME_M:-aarch64}" ;;
-n) if [[ ${SIDE:-local} == remote ]]; then echo us; else echo "${FAKE_HOST:-m2}"; fi ;;
esac
EOF
  # sudo never runs anything: it simulates the few root operations install.sh does,
  # against $STUBROOT/root. Flag files make individual operations fail.
  behave sudo <<'EOF'
r=$STUBROOT/root
case $1 in
tee) cat >/dev/null ;;
install)
  src=${@: -2:1} dst=${@: -1}
  [[ -f $STUBROOT/fail-install-$(basename "$dst") ]] && exit 1
  mkdir -p "$r$(dirname "$dst")" && cp "$src" "$r$dst" && cp "$src" "$STUBROOT/installed/$(basename "$dst")" ;;
test) [[ $2 == -f && -f $r$3 ]]; exit ;;
cat) cat "$r$2"; exit ;;
rm) rm -f "$r${@: -1}" ;;
sshd) # rejects a config with a Match block when asked to
  [[ -f $STUBROOT/sshd-rejects-match ]] && grep -qs '^Match' "$r/etc/ssh/sshd_config.d/10-dotfiles.conf" && exit 1 ;;
pacman) [[ $2 == -Syu && -f $STUBROOT/syu-fails ]] && exit 1 ;;
esac
EOF
  behave pacman <<'EOF'
case $1 in
-Slq)
  [[ -f $STUBROOT/empty-db ]] && exit 0
  grep -vhE '^[[:space:]]*(#|$)' "$STUBROOT/dots/packages/arch.txt"
  echo git; echo stow; echo base-devel ;;
-Qqen) echo pkg-a ;;
-Qqem) echo aur-b ;;
esac
EOF
  behave getent <<'EOF'
echo "$USER:x:1000:1000::$HOME:/usr/bin/zsh"
EOF
  behave dscl <<'EOF'
echo "UserShell: /bin/zsh"
EOF
  behave ssh-keygen <<'EOF'
f=${@: -1}; echo key >"$f"; echo "ssh-ed25519 AAAA test" >"$f.pub"
EOF
  behave tailscale <<'EOF'
case "$*" in
"ip -4") echo 100.73.76.10 ;;
"ip -6") echo fd7a:115c:a1e0::aa ;;
esac
EOF
  # ssh: SSH_MODE=ok (default) | batchfail (key needs a passphrase, no agent) |
  #      nokey (key not on the Legion until ssh-copy-id) | down
  behave ssh <<'EOF'
a=("$@") i=0
while [[ ${a[i]:-} == -* ]]; do case ${a[i]} in -[oOpiSlF]) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac; done
case ${SSH_MODE:-ok} in
down) exit 255 ;;
batchfail) [[ " $* " == *BatchMode=yes* ]] && exit 255 ;;
nokey) [[ " $* " == *PreferredAuthentications=publickey* && ! -f $STUBROOT/key-copied ]] && exit 255 ;;
esac
cmd=("${a[@]:i+1}")
((${#cmd[@]})) || exit 0
SIDE=remote bash -c "${cmd[*]}"
exit $? # (the remote command's status, like real ssh)
EOF
  behave ssh-copy-id <<'EOF'
case ${SSH_MODE:-ok} in
down) exit 1 ;;
nokey) touch "$STUBROOT/key-copied" ;;
esac
EOF
  # syncthing: a tiny fake config store per side (local / remote):
  #   devices, folders (IDs), path-<id>, vers-<id>, f-<id> (devices a folder is shared with)
  behave syncthing <<'EOF'
d=$STUBROOT/st/${SIDE:-local}
mkdir -p "$d"
touch "$d/devices" "$d/folders"
arg() { local k=$1; shift; while (($#)); do [[ $1 == "$k" ]] && { echo "$2"; return; }; shift; done; }
case "$*" in
device-id) echo "ID-${SIDE:-local}" ;;
"cli show system") ;;
"cli config devices list") cat "$d/devices" ;;
"cli config devices add "*)
  id=$(arg --device-id "$@")
  if grep -qx "$id" "$d/devices"; then echo "device exists" >&2; exit 1; fi
  if [[ -f $STUBROOT/race-armed ]]; then # another pair.sh run won the race
    rm "$STUBROOT/race-armed"; echo "$id" >>"$d/devices"; echo "device exists" >&2; exit 1
  fi
  echo "$id" >>"$d/devices" ;;
"cli config folders list")
  [[ ${SIDE:-local} == remote && -f $STUBROOT/remote-folders-fail ]] && exit 1
  cat "$d/folders"
  [[ -f $STUBROOT/bigfolders ]] && seq 1 200000 ;;
"cli config folders add "*)
  id=$(arg --id "$@"); echo "$id" >>"$d/folders"; arg --path "$@" >"$d/path-$id" ;;
"cli config folders "*" path get") cat "$d/path-$4" 2>/dev/null || echo "$HOME/$4" ;;
"cli config folders "*" delete")
  grep -vx "$4" "$d/folders" >"$d/folders.new"; mv "$d/folders.new" "$d/folders"
  p=$(cat "$d/path-$4" 2>/dev/null || echo "$HOME/$4"); [[ $p == "~" ]] && p=$HOME
  rm -rf "$p/.stfolder" ;;
"cli config folders "*" versioning type get") cat "$d/vers-$4" 2>/dev/null; true ;;
"cli config folders "*" versioning type set "*) echo "$8" >"$d/vers-$4" ;;
"cli config folders "*" versioning params set "*) echo "$8=$9" >>"$d/vparams-$4" ;;
"cli config folders "*" devices list") touch "$d/f-$4"; cat "$d/f-$4" ;;
"cli config folders "*" devices add "*) arg --device-id "$@" >>"$d/f-$4" ;;
esac
EOF
}

teardown() { rm -rf "$T"; }

stub() { # stub NAME: log the call, run $T/behave/NAME if present
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$STUBROOT/log"\n[[ -f $STUBROOT/behave/%s ]] && . "$STUBROOT/behave/%s"\nexit "${RC:-0}"\n' \
    "$1" "$1" "$1" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
behave() { cat >"$T/behave/$1"; }
unstub() { rm -f "$T/bin/$1"; }
unreal() { rm -f "$T/sys/$1"; }
flag() { touch "$T/$1"; }
decolor() { sed "s/$ESC\\[[0-9;]*m//g" "$T/out" >"$T/out.tmp" && mv "$T/out.tmp" "$T/out"; }

# run_install ARGS...: run the copy of install.sh in the sandbox (stdin: $INPUT or empty)
run_install() {
  local dots=${DOTSDIR:-$T/dots}
  env -i HOME="$T/home" USER="${USER_:-nex}" PATH="$T/bin:$T/sys" TMPDIR="$T/tmp" \
    STUBROOT="$T" TERM=dumb SSH_MODE="${SSH_MODE:-ok}" FAKE_HOST="${FAKE_HOST:-m2}" \
    FAKE_UNAME_S="${FAKE_UNAME_S:-Linux}" FAKE_UNAME_M="${FAKE_UNAME_M:-aarch64}" \
    DOTFILES_ARCH_RELEASE="${ARCH_RELEASE_:-$T/arch-release}" \
    bash "$dots/install.sh" "$@" <<<"${INPUT:-}" >"$T/out" 2>&1 && echo 0 >"$T/rc" || echo $? >"$T/rc"
  decolor
}
run_pair() {
  env -i HOME="$T/home" USER=nex PATH="$T/bin:$T/sys" TMPDIR="$T/tmp" STUBROOT="$T" \
    SSH_MODE="${SSH_MODE:-ok}" FAKE_HOST=m2 bash "$T/dots/syncthing/pair.sh" "${@:-us}" >"$T/out" 2>&1 &&
    echo 0 >"$T/rc" || echo $? >"$T/rc"
  decolor
}
remote_has_folders() { mkdir -p "$T/st/remote" && printf '%s\n' "$@" >"$T/st/remote/folders"; }
local_has_folders() { mkdir -p "$T/st/local" && printf '%s\n' "$@" >"$T/st/local/folders"; }
has_key() { mkdir -p "$T/home/.ssh" && echo "ssh-ed25519 AAAA mine" >"$T/home/.ssh/id_ed25519.pub"; }

# ---------- assertions ----------

fail() {
  printf '    %s\n' "$@" >&2
  printf '    --- output ---\n' >&2
  sed 's/^/    | /' "$T/out" >&2 2>/dev/null
  return 1
}
skip() {
  echo "    skipped: $*" >&2
  touch "$T/skipped"
}
rc_is() { [[ $(cat "$T/rc") == "$1" ]] || fail "exit code $(cat "$T/rc"), want $1"; }
rc_not() { [[ $(cat "$T/rc") != "$1" ]] || fail "exit code $1, want anything else"; }
out_has() { grep -qF -- "$1" "$T/out" || fail "output lacks: $1"; }
out_lacks() { ! grep -qF -- "$1" "$T/out" || fail "output has: $1"; }
log_has() { grep -qE -- "$1" "$T/log" 2>/dev/null || fail "no stub call matching: $1"; }
log_lacks() { ! grep -qE -- "$1" "$T/log" 2>/dev/null || fail "unexpected stub call: $1"; }
links_into_dots() { [[ $(readlink -f "$T/home/$1") == "$T/dots/"* ]] || fail "~/$1 is not linked into the repo"; }
is_private_dir() { [[ -d $1 && ! -L $1 && -n $(find "$1" -maxdepth 0 -perm 700) ]] || fail "$1 is not a real 0700 dir"; }
shared_with_remote() { grep -qx ID-local "$T/st/remote/f-$1" 2>/dev/null || fail "$1 not shared with the Legion"; }
local_folders_are() { [[ $(sort "$T/st/local/folders" 2>/dev/null | tr '\n' ' ') == "$1" ]] || fail "local folders: $(tr '\n' ' ' <"$T/st/local/folders" 2>/dev/null)"; }

# ---------- B1/R3/R4: sshd (M6) ----------

# passwordauth ADDR LADDR: what sshd decides for a connection from ADDR to LADDR
passwordauth() {
  "$SSHD" -T -f "$T/sshd_config" -h "$T/hostkey" -C "user=nex,host=x,addr=$1,laddr=$2" |
    awk 'tolower($1) == "passwordauthentication" { print $2 }'
}
installed_sshd_config() {
  local f=$T/installed/10-dotfiles.conf
  [[ -f $f ]] || fail "sshd drop-in not installed" || return 1
  ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey" </dev/null >/dev/null
  { cat "$f"; echo 'Subsystem sftp /usr/lib/ssh/sftp-server'; } >"$T/sshd_config"
}

t_B1_R3_sshd_passwords_only_from_tailnet_to_tailnet_address() {
  [[ -n $SSHD ]] || { skip "no sshd"; return 0; }
  run_install -y
  installed_sshd_config || return 1
  local addr laddr want got
  while read -r addr laddr want; do
    got=$(passwordauth "$addr" "$laddr")
    [[ $got == "$want" ]] || fail "from $addr to $laddr: passwords $got, want $want" || return 1
  done <<'EOF'
100.75.1.1 100.73.76.10 yes
100.64.9.9 100.64.1.2 no
192.168.1.9 100.73.76.10 no
100.75.1.1 192.168.1.5 no
100.115.92.5 100.73.76.10 no
fd7a:115c:a1e0::1 fd7a:115c:a1e0::aa no
EOF
}

t_B1_sshd_without_tailnet_ip_is_keys_only() {
  behave tailscale <<<'case "$*" in status|ip*) exit 1 ;; esac'
  run_install -y
  local f=$T/installed/10-dotfiles.conf
  [[ -f $f ]] || fail "sshd drop-in not installed" || return 1
  ! grep -qE '^[[:space:]]*PasswordAuthentication yes' "$f" || fail "passwords enabled with no tailnet address"
}

t_R3_sshd_password_rule_does_not_need_ipv6() {
  behave tailscale <<<'case "$*" in "ip -4") echo 100.73.76.10 ;; "ip -6") exit 1 ;; esac'
  run_install -y
  grep -q '^Match LocalAddress 100.73.76.10 ' "$T/installed/10-dotfiles.conf" ||
    fail "IPv6 lookup failing dropped the IPv4 rule"
}

t_R4_rejected_sshd_config_keeps_the_previous_one() {
  mkdir -p "$T/root/etc/ssh/sshd_config.d"
  echo OLD-CONFIG >"$T/root/etc/ssh/sshd_config.d/10-dotfiles.conf"
  flag sshd-rejects-match
  run_install -y
  [[ $(cat "$T/root/etc/ssh/sshd_config.d/10-dotfiles.conf") == OLD-CONFIG ]] ||
    fail "previous sshd drop-in was not restored" || return 1
  rc_is 1 && out_has "previous one is still in place" && log_lacks 'sudo systemctl reload sshd'
}

t_R4_rejected_sshd_config_without_previous_is_removed() {
  flag sshd-rejects-match
  run_install -y
  [[ ! -e $T/root/etc/ssh/sshd_config.d/10-dotfiles.conf ]] || fail "rejected drop-in left installed" || return 1
  log_lacks 'sudo systemctl reload sshd'
}

# ---------- B2/B3/R6/R7/R10/B12/B13: run mode + pipeline (M1, M2, M5) ----------

t_B2_dry_run_on_fresh_machine_completes() {
  unstub yay
  unreal stow
  run_install -n -y
  rc_is 0 && out_has "==> done" && log_lacks '^makepkg' && log_lacks '^sudo'
}

t_R10_dry_run_with_empty_package_db() {
  flag empty-db
  run_install -n -y
  rc_is 0 && out_has "[dry] sudo pacman -S --needed" && out_lacks "not in repos"
}

t_B3_link_failure_does_not_abort_the_run() {
  FAKE_UNAME_S=FreeBSD
  unreal stow
  unreal realpath
  run_install -y
  rc_is 1 && out_has "writing ~/.gitconfig.local" && out_has "==> done" && out_has "linking configs"
}

t_B3_yay_bootstrap_failure_is_reported_and_cleaned_up() {
  unstub yay
  behave git <<<'[[ $1 == clone ]] && mkdir -p "${@: -1}"'
  stub git
  behave makepkg <<<'exit 1'
  run_install -y
  rc_is 1 && out_has "yay" && out_has "==> done" || return 1
  [[ -z $(ls -A "$T/tmp") ]] || fail "temp dir left behind: $(ls "$T/tmp")"
}

t_B3_exit_status_is_zero_when_nothing_failed() {
  run_install -y
  rc_is 0
}

t_R6_failures_mid_run_still_reach_the_summary() {
  flag fail-install-pkglist.hook
  behave ssh-keygen <<<'exit 1'
  run_install -y
  rc_is 1 && out_has "pacman hook" && out_has "ssh key" && out_has "writing ~/.gitconfig.local" && out_has "==> done"
}

t_B12_package_databases_are_refreshed_first() {
  run_install -y
  local first
  first=$(grep -m1 '^sudo pacman -S' "$T/log")
  [[ $first == "sudo pacman -Syu "* ]] || fail "first pacman call: $first"
}

t_R7_failed_upgrade_installs_nothing() {
  flag syu-fails
  run_install -y
  rc_is 1 && out_has "no packages were installed" && out_has "linking:" && out_has "==> done" || return 1
  log_lacks '^sudo pacman -S --needed' && log_lacks '^yay -S'
}

t_B13_help_prints_only_usage() {
  run_install -h
  rc_is 0 && out_has "--link" && out_lacks "set -euo"
}

# ---------- B4/B5/R2/R8/R11: linking + backups (M3, M4) ----------

t_B4_backup_dir_is_unique_per_run() {
  behave date <<<'echo 20260101-000000'
  stub date
  echo original >"$T/home/.zshrc"
  run_install --link -y
  links_into_dots .zshrc || return 1
  # second run in the same second, and stow fails, so it restores its own backups
  rm "$T/home/.config/starship.toml"
  echo mine >"$T/home/.config/starship.toml"
  behave stow <<<'exit 1'
  stub stow
  run_install --link -y
  links_into_dots .zshrc || fail "a later run restored an earlier run's backup over the link" || return 1
  [[ $(cat "$T/home/.config/starship.toml") == mine ]] || fail "this run's own backup was not restored" || return 1
  grep -rqx original "$T/home/.dotfiles-backup" || fail "the first run's backup of .zshrc is gone"
}

t_R8_restore_puts_back_dirs_and_empty_dirs() {
  mkdir -p "$T/home/.zshrc" "$T/home/.config/starship.toml/sub"
  behave stow <<<'exit 1'
  stub stow
  run_install --link -y
  [[ -d $T/home/.zshrc && ! -L $T/home/.zshrc ]] || fail "empty dir ~/.zshrc not restored" || return 1
  [[ -d $T/home/.config/starship.toml/sub ]] || fail "~/.config/starship.toml/sub not restored" || return 1
  out_has "restored your original files"
}

t_B5_symlinked_config_dir_is_not_moved() {
  mkdir -p "$T/elsewhere/app"
  echo keep >"$T/elsewhere/app/settings"
  ln -s "$T/elsewhere" "$T/home/.config"
  run_install --link -y
  [[ -L $T/home/.config && $(cat "$T/home/.config/app/settings" 2>/dev/null) == keep ]] ||
    fail "~/.config (a symlink to another disk) was moved away" || return 1
  links_into_dots .zshrc && out_has "skipped"
}

t_R2_file_at_ssh_never_folds_keys_into_the_repo() {
  echo junk >"$T/home/.ssh"
  run_install -y
  is_private_dir "$T/home/.ssh" || return 1
  links_into_dots .ssh/config || return 1
  [[ -z $(ls -A "$T/dots/ssh/.ssh" | grep -vx config) ]] ||
    fail "files written into the repo: $(ls -A "$T/dots/ssh/.ssh")" || return 1
  grep -rqx junk "$T/home/.dotfiles-backup" || fail "the original ~/.ssh file wasn't backed up"
}

t_R2_folded_ssh_dir_is_unfolded() {
  ln -s "$T/dots/ssh/.ssh" "$T/home/.ssh"
  run_install --link -y
  is_private_dir "$T/home/.ssh" && links_into_dots .ssh/config
}

t_R2_no_keys_written_when_ssh_points_into_repo() {
  FAKE_UNAME_S=FreeBSD # linking can't run (no stow/realpath), so ~/.ssh stays a link into the repo
  unreal stow
  unreal realpath
  ln -s "$T/dots/ssh/.ssh" "$T/home/.ssh"
  run_install -y
  [[ ! -e $T/dots/ssh/.ssh/id_ed25519 ]] || fail "private key written into the repo" || return 1
  out_has "refusing to write keys"
}

t_R11_link_only_makes_ssh_dir_private() {
  umask 002
  run_install --link -y
  is_private_dir "$T/home/.ssh"
}

# ---------- B6/B7: git + personal boundary (M1, M7) ----------

t_B6_gitconfig_local_keeps_user_settings() {
  has_key
  printf '[alias]\n\tco = checkout\n' >"$T/home/.gitconfig.local"
  echo "me@dnex.dev ssh-ed25519 BBBB other-machine" >"$T/home/.ssh/allowed_signers"
  run_install -y
  run_install -y
  local g=$T/home/.gitconfig.local s=$T/home/.ssh/allowed_signers
  grep -q 'co = checkout' "$g" || fail "user's [alias] lost" || return 1
  grep -q "signingkey = $T/home/.ssh/id_ed25519.pub" "$g" || fail "signing key not set" || return 1
  grep -q 'BBBB other-machine' "$s" || fail "other machine's signer line lost" || return 1
  [[ $(grep -c 'AAAA mine' "$s") == 1 ]] || fail "own signer line missing or duplicated"
}

t_B7_guest_gets_no_personal_identity() {
  USER_=guest run_install -y
  rc_is 0 || return 1
  [[ ! -e $T/home/.gitconfig && ! -e $T/home/.ssh/config ]] || fail "guest got nex's .gitconfig or ssh hosts" || return 1
  out_has "personal setup skipped" && log_lacks '^ssh-keygen' && log_lacks '^tailscale' && log_lacks 'tailscaled'
}

# ---------- B8/R9: Legion connection (M10) ----------

t_B8_R9_pairing_works_with_a_passphrase_key() {
  has_key
  remote_has_folders code notes Documents
  SSH_MODE=batchfail run_install -y
  shared_with_remote code && log_lacks '^ssh-copy-id'
}

t_R9_key_is_copied_then_verified_before_pairing() {
  has_key
  remote_has_folders code notes Documents
  SSH_MODE=nokey run_install -y
  log_has '^ssh-copy-id' && shared_with_remote code && rc_is 0
}

t_B8_R9_unreachable_legion_is_reported() {
  has_key
  remote_has_folders code notes Documents
  SSH_MODE=down run_install -y
  rc_is 1 && out_has "Legion (us) not reachable" && out_has "pair.sh us" || return 1
  [[ ! -s $T/st/remote/f-code ]] || fail "pairing ran although the Legion is unreachable"
}

# ---------- B9/B10/B11/R5/R12: Syncthing folders + pairing (M8, M9) ----------

t_B9_pair_uses_the_shared_folder_list() {
  printf 'code\nmusic\n' >"$T/dots/syncthing/folders"
  local_has_folders code music
  remote_has_folders code music
  run_pair
  rc_is 0 && shared_with_remote music
}

t_B9_install_creates_folders_from_the_shared_list() {
  printf 'code\nmusic\n' >"$T/dots/syncthing/folders"
  run_install -y
  local_folders_are "code music " || return 1
  [[ -L $T/home/music/.stignore ]] || fail "~/music/.stignore not linked"
}

t_R12_folder_list_comments_parse_the_same_everywhere() {
  printf 'code   # source code\nnotes\n' >"$T/dots/syncthing/folders"
  remote_has_folders code notes
  has_key
  run_install -y
  local_folders_are "code notes " && shared_with_remote code
}

t_R12_bad_folder_entry_is_rejected() {
  printf 'code\n../etc\n' >"$T/dots/syncthing/folders"
  run_install -y
  rc_is 1 && out_has "bad entry" || return 1
  [[ ! -s $T/st/local/folders ]] || fail "folders were added from a bad list"
}

t_R1_R12_repo_path_with_spaces() {
  mv "$T/dots" "$T/my dots"
  ln -s "$T/my dots" "$T/dots" # (fixture helpers still look in $T/dots)
  has_key
  remote_has_folders code notes Documents
  DOTSDIR="$T/my dots" run_install -y
  out_has "path without spaces" && shared_with_remote code
}

t_B10_pair_survives_a_concurrent_pair_run() {
  local_has_folders code notes Documents
  remote_has_folders code notes Documents
  flag race-armed
  run_pair
  rc_is 0 && shared_with_remote code
}

t_R5_pair_fails_when_a_list_command_fails() {
  local_has_folders code notes Documents
  remote_has_folders code notes Documents
  flag remote-folders-fail
  run_pair
  rc_not 0 && out_lacks "paired"
}

# ---------- S: whole-home sync (M8) ----------

t_S1_home_is_one_folder_with_the_ignore_list() {
  printf '~\n' >"$T/dots/syncthing/folders"
  run_install -y
  rc_is 0 && local_folders_are "home " || return 1
  [[ $(cat "$T/st/local/path-home") == "$T/home" ]] || fail "home folder path: $(cat "$T/st/local/path-home")" || return 1
  [[ $(readlink -f "$T/home/.stignore") == "$T/dots/syncthing/stignore" ]] || fail "~/.stignore not linked"
}

t_S2_whole_home_cannot_be_combined_with_other_folders() {
  printf '~\ncode\n' >"$T/dots/syncthing/folders"
  run_pair --folders
  rc_not 0 && out_has "overlap" || return 1
  printf 'code\ncode/sub\n' >"$T/dots/syncthing/folders"
  run_pair --folders
  rc_not 0 && out_has "overlap"
}

t_S3_switching_to_home_drops_nested_folders_but_keeps_files() {
  local_has_folders code notes Documents music-elsewhere
  echo "$T/home/code" >"$T/st/local/path-code"
  echo "$T/elsewhere" >"$T/st/local/path-music-elsewhere"
  mkdir -p "$T/home/code"
  echo work >"$T/home/code/file"
  printf '~\n' >"$T/dots/syncthing/folders"
  run_install -y
  rc_is 0 && local_folders_are "home music-elsewhere " || return 1
  [[ $(cat "$T/home/code/file") == work ]] || fail "files in the old folder were touched"
}

t_S3_old_folder_stored_as_tilde_is_dropped() {
  # the web UI stores a folder added as "~" with the literal path "~", not /home/...
  local_has_folders wbqxu-nqjne
  echo "~" >"$T/st/local/path-wbqxu-nqjne"
  printf '~\n' >"$T/dots/syncthing/folders"
  mkdir "$T/home/.stfolder" # the fake syncthing deletes it with the "~" folder, like the real one
  run_install -y
  rc_is 0 && local_folders_are "home " || return 1
  [[ -d $T/home/.stfolder ]] || fail "folder marker ~/.stfolder missing after the migration"
}

t_S4_new_folders_get_30_day_versioning_unless_already_set() {
  local_has_folders notes
  echo staggered >"$T/st/local/vers-notes"
  run_install -y
  [[ $(cat "$T/st/local/vers-code") == trashcan ]] || fail "code versioning: $(cat "$T/st/local/vers-code" 2>/dev/null)" || return 1
  grep -qx 'cleanoutDays=30' "$T/st/local/vparams-code" || fail "no cleanoutDays=30" || return 1
  [[ $(cat "$T/st/local/vers-notes") == staggered ]] || fail "user's versioning choice was overwritten"
}

t_S5_ignore_list_keeps_per_machine_state_out() {
  local f=$T/dots/syncthing/stignore p
  for p in /.local/state/syncthing /.config/syncthing /.ssh /.gnupg /.local/share/keyrings \
    '/dotfiles/*' /.cache /.local/bin /.local/share/nvim /.zen /.config/zen /.mozilla /.config/mozilla /.config/evolution /.espressif /esp/esp-idf /.local/mamba /yay /.sbt /.config/dconf /.zsh_history node_modules target; do
    grep -qxF -- "$p" "$f" || fail "stignore doesn't ignore $p" || return 1
  done
  # these must NOT be ignored: they are what the user wants mirrored
  for p in /code /Documents /Downloads /Projects /Pictures /notes /.config/thunderbird /.thunderbird; do
    ! grep -qxF -- "$p" "$f" || fail "stignore ignores $p" || return 1
  done
}

t_S7_private_and_docs_sync_but_stay_out_of_git() {
  local f=$T/dots/syncthing/stignore inc
  # Syncthing: first match wins, so the ! lines must come before /dotfiles/*
  for inc in '!/dotfiles/docs' '!/dotfiles/private'; do
    (($(grep -nxF -- "$inc" "$f" | cut -d: -f1) < $(grep -nxF '/dotfiles/*' "$f" | cut -d: -f1))) ||
      fail "$inc missing or after /dotfiles/*" || return 1
  done
  (cd "$REPO" && git check-ignore -q docs/x.md && git check-ignore -q private/ssh_config) ||
    fail "docs/ or private/ is not gitignored" || return 1
  # the public ssh config pulls private settings in first, and names no user but nex
  [[ $(grep -m1 '^Include' "$T/dots/ssh/.ssh/config") == 'Include ~/dotfiles/private/ssh_config' ]] ||
    fail "ssh config doesn't include the private file first" || return 1
  ! grep -E '^[[:space:]]*User[[:space:]]' "$T/dots/ssh/.ssh/config" | grep -vq 'User nex' ||
    fail "a user name other than nex is in the public ssh config"
}

t_S6_pair_shares_the_home_folder() {
  printf '~\n' >"$T/dots/syncthing/folders"
  local_has_folders home
  remote_has_folders home
  run_pair
  rc_is 0 && shared_with_remote home
}

# ---------- R1: package snapshots (M11) ----------

t_R1_snapshot_never_writes_through_a_symlink() {
  echo victim >"$T/victim"
  rm -f "$T/dots/pkglist-m2.txt" "$T/dots/aur-m2.txt"
  ln -s "$T/victim" "$T/dots/pkglist-m2.txt"
  env -i PATH="$T/bin:$T/sys" STUBROOT="$T" TMPDIR="$T/tmp" FAKE_HOST=m2 \
    sh "$T/dots/system/pkglist-snapshot" "$T/dots" >"$T/out" 2>&1
  [[ $(cat "$T/victim") == victim ]] || fail "wrote through the symlink" || return 1
  [[ -f $T/dots/pkglist-m2.txt && ! -L $T/dots/pkglist-m2.txt && $(cat "$T/dots/pkglist-m2.txt") == pkg-a ]] ||
    fail "pkglist-m2.txt not replaced by a regular file" || return 1
  [[ $(cat "$T/dots/aur-m2.txt") == aur-b ]] || fail "aur-m2.txt wrong" || return 1
  [[ -z $(find "$T/dots" -maxdepth 1 -name '.snapshot.*') ]] || fail "temp file left behind"
}

t_R1_hook_runs_the_snapshot_as_the_user() {
  run_install -y
  local h=$T/installed/pkglist.hook
  [[ -f $h && -f $T/installed/pkglist-snapshot ]] || fail "hook or helper not installed" || return 1
  grep -q "^Exec = /usr/bin/runuser -u nex -- /usr/local/lib/dotfiles/pkglist-snapshot $T/dots\$" "$h" ||
    fail "hook Exec: $(grep Exec "$h")" || return 1
  ! grep -q '>' "$h" || fail "hook still redirects output as root"
}

# ---------- R14: macOS ----------

t_R14_macos_full_run() {
  FAKE_UNAME_S=Darwin
  stub brew
  has_key
  remote_has_folders code notes Documents
  run_install -y
  rc_is 0 || return 1
  log_has '^brew bundle' && log_has '^brew services start syncthing' && out_lacks "niri" &&
    links_into_dots .zshrc && shared_with_remote code && log_lacks '^sudo'
}

t_R6_R14_macos_homebrew_download_failure_is_reported() {
  FAKE_UNAME_S=Darwin
  behave curl <<<'exit 22'
  run_install -y
  rc_is 1 && out_has "homebrew" && out_has "==> done"
}

# ---------- runner ----------

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  [[ -z $FILTER || $t == *"$FILTER"* ]] || continue
  setup
  (
    set -e
    "$t"
  )
  if (($? != 0)); then
    FAILED+=("$t")
    printf '\033[31mFAIL\033[0m %s\n' "$t"
  elif [[ -f $T/skipped ]]; then
    SKIPPED=$((SKIPPED + 1))
    printf '\033[33mskip\033[0m %s\n' "$t"
  else
    PASSED=$((PASSED + 1))
    printf '\033[32mok\033[0m   %s\n' "$t"
  fi
  teardown
done
echo
echo "$PASSED passed, ${#FAILED[@]} failed, $SKIPPED skipped"
((${#FAILED[@]} == 0))
