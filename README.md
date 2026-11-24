# dotfiles

Arch Linux, Debian 13, Ubuntu 24.04 and Apple Silicon macOS.

On Debian/Ubuntu you get the shell, neovim, git and alacritty setup; the niri/dms desktop is only linked if niri is already installed. No sudo? It notices (or pass `--no-sudo`) and installs zsh, neovim and the CLI tools into `~/.local` instead.

```sh
git clone https://github.com/dnexdev/dotfiles ~/dotfiles && 
bash ~/dotfiles/install.sh
```
