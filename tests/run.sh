#!/usr/bin/env bash
# Regression tests for install.sh and syncthing/pair.sh. See docs/state-machines.md
# for the states and bugs each test pins down (the B-numbers).
#
# Hermetic: every test copies the repo to a temp dir, gets a fake $HOME, and runs with a
# PATH that holds only stubs plus a whitelist of harmless real tools. Stubs log every call
# to $STUBROOT/log and never touch the real system (sudo, pacman, systemctl, ssh, ...).
#
# usage: tests/run.sh [substring to select tests]
set -uo pipefail

REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILTER=${1:-}
PASSED=0 FAILED=()

REAL=(bash sh env cat cp mv rm ln mkdir rmdir chmod readlink basename dirname find grep
  sed awk cut tr sort head tail tee mktemp date sleep touch wc perl stow diff git seq paste id)
STUBS=(uname sudo pacman yay makepkg curl systemctl loginctl chsh getent ssh ssh-copy-id
  ssh-keygen tailscale syncthing sshd)

# ---------- fixture ----------

setup() {
  T=$(mktemp -d)
  export STUBROOT=$T
  mkdir -p "$T/home" "$T/bin" "$T/sys" "$T/behave" "$T/tmp" "$T/installed"
  (cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) |
    (mkdir -p "$T/dots" && cd "$T/dots" && tar -xf -)
  local t
  for t in "${REAL[@]}"; do ln -s "$(command -v "$t")" "$T/sys/$t"; done
  for t in "${STUBS[@]}"; do stub "$t"; done

  behave uname <<'EOF'
case $1 in
-s) echo "${FAKE_UNAME_S:-Linux}" ;;
-m) echo "${FAKE_UNAME_M:-aarch64}" ;;
-n) if [[ ${SIDE:-local} == remote ]]; then echo us; else echo "${FAKE_HOST:-m2}"; fi ;;
esac
EOF
  behave sudo <<'EOF'
case $1 in
tee) cat >/dev/null ;;
install) cp "${@: -2:1}" "$STUBROOT/installed/$(basename "${@: -1}")" ;;
esac
EOF
  behave pacman <<'EOF'
if [[ $1 == -Slq ]]; then
  grep -vhE '^[[:space:]]*(#|$)' "$STUBROOT/dots/packages/arch.txt"
  echo git; echo stow; echo base-devel
fi
EOF
  behave getent <<'EOF'
echo "$USER:x:1000:1000::$HOME:/usr/bin/zsh"
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
  # ssh: SSH_MODE=ok (default) | batchfail (key needs a passphrase, no agent) | down
  behave ssh <<'EOF'
a=("$@") i=0
while [[ ${a[i]:-} == -* ]]; do case ${a[i]} in -[oOpiSlF]) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac; done
case ${SSH_MODE:-ok} in
down) exit 255 ;;
batchfail) [[ " $* " == *BatchMode=yes* ]] && exit 255 ;;
esac
cmd=("${a[@]:i+1}")
((${#cmd[@]})) || exit 0
SIDE=remote bash -c "${cmd[*]}"
EOF
  # syncthing: a tiny fake config store per side (local / remote)
  behave syncthing <<'EOF'
d=$STUBROOT/st/${SIDE:-local}
mkdir -p "$d"
touch "$d/devices" "$d/folders"
arg() { local k=$1; shift; while (($#)); do [[ $1 == "$k" ]] && { echo "$2"; return; }; shift; done; }
case "$*" in
device-id) echo "ID-${SIDE:-local}" ;;
"cli show system") ;;
"cli config devices list") cat "$d/devices"; [[ -f $STUBROOT/race ]] && rm "$STUBROOT/race" ;;
"cli config devices add "*)
  id=$(arg --device-id "$@")
  if grep -qx "$id" "$d/devices"; then echo "device exists" >&2; exit 1; fi
  if [[ -f $STUBROOT/race-armed ]]; then # another pair.sh run won the race
    rm "$STUBROOT/race-armed"; echo "$id" >>"$d/devices"; echo "device exists" >&2; exit 1
  fi
  echo "$id" >>"$d/devices" ;;
"cli config folders list")
  cat "$d/folders"
  [[ -f $STUBROOT/bigfolders ]] && seq 1 200000 ;;
"cli config folders add "*) arg --id "$@" >>"$d/folders" ;;
"cli config folders "*" devices list") touch "$d/f-$4"; cat "$d/f-$4" ;;
"cli config folders "*" devices add "*) arg --device-id "$@" >>"$d/f-$4" ;;
esac
EOF
}

teardown() { rm -rf "$T"; }

stub() { # stub NAME: log the call, run $T/behave/NAME if present
  printf '#!/usr/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$STUBROOT/log"\n[[ -f $STUBROOT/behave/%s ]] && . "$STUBROOT/behave/%s"\nexit "${RC:-0}"\n' \
    "$1" "$1" "$1" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
behave() { cat >"$T/behave/$1"; }
unstub() { rm -f "$T/bin/$1"; }
unreal() { rm -f "$T/sys/$1"; }

# run_install ARGS...: run the copy of install.sh in the sandbox (stdin: $INPUT or empty)
run_install() {
  env -i HOME="$T/home" USER="${USER_:-nex}" PATH="$T/bin:$T/sys" TMPDIR="$T/tmp" \
    STUBROOT="$T" TERM=dumb SSH_MODE="${SSH_MODE:-ok}" FAKE_HOST="${FAKE_HOST:-m2}" \
    FAKE_UNAME_S="${FAKE_UNAME_S:-Linux}" FAKE_UNAME_M="${FAKE_UNAME_M:-aarch64}" \
    bash "$T/dots/install.sh" "$@" <<<"${INPUT:-}" >"$T/out" 2>&1 && echo 0 >"$T/rc" || echo $? >"$T/rc"
  sed -i 's/\x1b\[[0-9;]*m//g' "$T/out" # drop colours
}
run_pair() {
  env -i HOME="$T/home" USER=nex PATH="$T/bin:$T/sys" STUBROOT="$T" SSH_MODE="${SSH_MODE:-ok}" \
    FAKE_HOST=m2 bash "$T/dots/syncthing/pair.sh" us >"$T/out" 2>&1 && echo 0 >"$T/rc" || echo $? >"$T/rc"
  sed -i 's/\x1b\[[0-9;]*m//g' "$T/out" # drop colours
}

# ---------- assertions ----------

fail() {
  printf '    %s\n' "$@" >&2
  printf '    --- output ---\n' >&2
  sed 's/^/    | /' "$T/out" >&2 2>/dev/null
  return 1
}
rc_is() { [[ $(cat "$T/rc") == "$1" ]] || fail "exit code $(cat "$T/rc"), want $1"; }
out_has() { grep -qF -- "$1" "$T/out" || fail "output lacks: $1"; }
out_lacks() { ! grep -qF -- "$1" "$T/out" || fail "output has: $1"; }
log_has() { grep -qE -- "$1" "$T/log" 2>/dev/null || fail "no stub call matching: $1"; }
log_lacks() { ! grep -qE -- "$1" "$T/log" 2>/dev/null || fail "unexpected stub call: $1"; }
links_into_dots() { [[ $(readlink -f "$T/home/$1") == "$T/dots/"* ]] || fail "~/$1 is not linked into the repo"; }

# ---------- tests (one per bug; B-numbers are in docs/state-machines.md) ----------

t_B1_sshd_passwords_only_on_tailnet_address() {
  run_install -y
  local f=$T/installed/10-dotfiles.conf
  [[ -f $f ]] || fail "sshd drop-in not installed" || return 1
  ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey" </dev/null >/dev/null
  { cat "$f"; echo 'Subsystem sftp /usr/lib/ssh/sftp-server'; } >"$T/sshd_config"
  spec() { /usr/bin/sshd -T -f "$T/sshd_config" -h "$T/hostkey" -C "user=nex,host=x,$1" | grep -i '^passwordauthentication'; }
  # ISP carrier-grade NAT peer hitting the machine's own CGNAT WAN address: must be keys only
  [[ $(spec addr=100.64.9.9,laddr=100.64.1.2) == *" no" ]] || fail "CGNAT peer gets passwords: $(spec addr=100.64.9.9,laddr=100.64.1.2)"
  [[ $(spec addr=100.75.1.1,laddr=100.73.76.10) == *" yes" ]] || fail "tailnet peer can't use a password"
  [[ $(spec addr=192.168.1.9,laddr=100.73.76.10) == *" no" ]] || fail "LAN host reaching the Tailscale address gets passwords (R3)"
  [[ $(spec addr=100.115.92.5,laddr=100.73.76.10) == *" no" ]] || fail "unfiltered 100.115.92.0/23 gets passwords"
  [[ $(spec addr=fd7a:115c:a1e0::1,laddr=fd7a:115c:a1e0::aa) == *" no" ]] || fail "IPv6 has no anti-spoof rule, must be keys only"
}

t_B1_sshd_without_tailnet_ip_is_keys_only() {
  behave tailscale <<<'case "$*" in status|ip*) exit 1 ;; esac'
  run_install -y
  local f=$T/installed/10-dotfiles.conf
  [[ -f $f ]] || fail "sshd drop-in not installed" || return 1
  ! grep -qE '^[[:space:]]*PasswordAuthentication yes' "$f" || fail "passwords enabled with no tailnet address"
}

t_B2_dry_run_on_fresh_machine_completes() {
  unstub yay
  unreal stow
  run_install -n -y
  rc_is 0 && out_has "==> done" && log_lacks '^makepkg' && log_lacks '^sudo'
}

t_B3_link_failure_does_not_abort_the_run() {
  FAKE_UNAME_S=FreeBSD
  unreal stow
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
  [[ $(cat "$T/home/.config/starship.toml") == mine ]] || fail "this run's own backup was not restored"
  grep -rqx original "$T/home/.dotfiles-backup" || fail "the first run's backup of .zshrc is gone"
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

t_B6_gitconfig_local_keeps_user_settings() {
  mkdir -p "$T/home/.ssh"
  echo "ssh-ed25519 AAAA mine" >"$T/home/.ssh/id_ed25519.pub"
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

t_B8_pairing_works_with_a_passphrase_key() {
  mkdir -p "$T/home/.ssh"
  echo "ssh-ed25519 AAAA mine" >"$T/home/.ssh/id_ed25519.pub"
  mkdir -p "$T/st/remote" && printf 'code\nnotes\nDocuments\n' >"$T/st/remote/folders"
  SSH_MODE=batchfail run_install -y
  grep -qx ID-local "$T/st/remote/f-code" 2>/dev/null || fail "pairing was skipped"
}

t_B8_unreachable_legion_is_reported() {
  mkdir -p "$T/home/.ssh"
  echo "ssh-ed25519 AAAA mine" >"$T/home/.ssh/id_ed25519.pub"
  SSH_MODE=down run_install -y
  rc_is 1 && out_has "pair.sh us"
}

t_B9_pair_uses_the_shared_folder_list() {
  printf 'code\nmusic\n' >"$T/dots/syncthing/folders"
  mkdir -p "$T/st/local" "$T/st/remote"
  printf 'code\nmusic\n' | tee "$T/st/local/folders" >"$T/st/remote/folders"
  run_pair
  rc_is 0 && grep -qx ID-local "$T/st/remote/f-music" || fail "music not shared"
}

t_B9_install_creates_folders_from_the_shared_list() {
  printf 'code\nmusic\n' >"$T/dots/syncthing/folders"
  run_install -y
  [[ $(sort "$T/st/local/folders" | tr '\n' ' ') == "code music " ]] || fail "folders: $(cat "$T/st/local/folders")" || return 1
  [[ -L $T/home/music/.stignore ]] || fail "~/music/.stignore not linked"
}

t_B10_pair_survives_a_concurrent_pair_run() {
  mkdir -p "$T/st/local" "$T/st/remote"
  printf 'code\nnotes\nDocuments\n' | tee "$T/st/local/folders" >"$T/st/remote/folders"
  touch "$T/race-armed"
  run_pair
  rc_is 0 || return 1
  grep -qx ID-local "$T/st/remote/f-code" || fail "folders not shared after the race"
}

t_B11_folder_check_survives_sigpipe() {
  mkdir -p "$T/st/local"
  printf 'code\nnotes\nDocuments\n' >"$T/st/local/folders"
  touch "$T/bigfolders"
  run_install -y
  log_lacks 'syncthing cli config folders add'
}

t_B12_package_databases_are_refreshed_first() {
  run_install -y
  local first
  first=$(grep -m1 '^sudo pacman -S' "$T/log")
  [[ $first == "sudo pacman -Syu "* ]] || fail "first pacman call: $first"
}

t_B13_help_prints_only_usage() {
  run_install -h
  rc_is 0 && out_has "--link" && out_lacks "set -euo"
}

# ---------- runner ----------

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  [[ -z $FILTER || $t == *"$FILTER"* ]] || continue
  setup
  (
    set -e
    "$t"
  )
  if (($? == 0)); then
    PASSED=$((PASSED + 1))
    printf '\033[32mok\033[0m   %s\n' "$t"
  else
    FAILED+=("$t")
    printf '\033[31mFAIL\033[0m %s\n' "$t"
  fi
  teardown
done
echo
echo "$PASSED passed, ${#FAILED[@]} failed"
((${#FAILED[@]} == 0))
