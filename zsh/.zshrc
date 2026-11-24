# history
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS SHARE_HISTORY
setopt NO_BEEP

# environment
export EDITOR=nvim VISUAL=nvim PAGER=less
typeset -U path # no duplicates
path=(~/.local/bin ~/.cargo/bin $path)

# vi mode
bindkey -v
export KEYTIMEOUT=1
bindkey -v '^?' backward-delete-char
bindkey '^R' history-incremental-search-backward
bindkey '^F' autosuggest-accept

# completion
[[ -d /opt/homebrew/share/zsh-completions ]] && fpath=(/opt/homebrew/share/zsh-completions $fpath)
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# tools
(( $+commands[zoxide] ))   && eval "$(zoxide init zsh --cmd cd)"
(( $+commands[starship] )) && eval "$(starship init zsh)"

# aliases
alias vim='nvim' v='nvim .'
alias cp='cp -i' mv='mv -i'
alias ..='cd ..' ...='cd ../..' ....='cd ../../..'
alias r='exec zsh'

if (( $+commands[eza] )); then
  alias ls='eza --group-directories-first'
  alias ll='eza -hal --group-directories-first'
  alias lt='eza --tree -a --group-directories-first -I .git'
else
  alias ll='ls -lah'
fi
(( $+commands[trash-put] )) && alias del='trash-put'

# git
alias gs='git status' gd='git diff' gl='git log --oneline --graph --decorate -20'

alias g++20='g++ -std=c++20 -fmodules-ts -Wall -g'
alias g++20h='g++ -std=c++20 -fmodules-ts -c -x c++-system-header'

mkcd() { mkdir -p -- "$1" && cd -- "$1"; }

up() { local d=""; for ((i = 1; i <= ${1:-1}; i++)); do d+="../"; done; cd "$d"; }

extract() {
  for f in "$@"; do
    case "$f" in
      *.tar*|*.tgz|*.tbz2|*.txz) tar xf "$f" ;;   # tar auto-detects compression
      *.zip) unzip "$f" ;;
      *.7z)  7z x "$f" ;;
      *.rar) unrar x "$f" ;;
      *.gz)  gunzip "$f" ;;
      *)     echo "extract: don't know how to handle '$f'" ;;
    esac
  done
}


for p in /usr/share/zsh/plugins /usr/share ~/.local/share/zsh/plugins /opt/homebrew/share; do
  [[ -f $p/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source $p/zsh-autosuggestions/zsh-autosuggestions.zsh
done
for p in /usr/share/zsh/plugins /usr/share ~/.local/share/zsh/plugins /opt/homebrew/share; do
  [[ -f $p/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source $p/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
done
