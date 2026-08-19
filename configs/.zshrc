export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="agnoster"

HYPHEN_INSENSITIVE="true"

ENABLE_CORRECTION="false"

COMPLETION_WAITING_DOTS="true"

HIST_STAMPS="yyyy-mm-dd"

plugins=(
    git
    zsh-autosuggestions
    extract
    z
    fzf
    eza
    colored-man-pages
    command-not-found
    sudo
    history
    copypath
    copyfile
    dirhistory
    web-search
    zsh-syntax-highlighting
)

# oh-my-zsh may not be installed yet (e.g. first shell after a restore that
# failed mid-way) — never let a missing $ZSH break every interactive shell.
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

export PATH="$HOME/.local/bin:$PATH"

command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

export EDITOR="nvim"
export VISUAL="nvim"

export LANG="zh_CN.UTF-8"
export LANGUAGE="zh_CN:en_US"

HISTSIZE=50000
SAVEHIST=50000
HISTFILE="$HOME/.zsh_history"
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY

# eza aliases only when eza exists (Debian 12 / Ubuntu 24.04 have no eza package)
if command -v eza >/dev/null 2>&1; then
    alias ls="eza"
    alias ll="eza -lah"
    alias la="eza -a"
    alias lt="eza --tree"
    alias l="eza -l"
fi

# bat is installed as batcat on Debian/Ubuntu (a symlink is created by install.sh)
if command -v bat >/dev/null 2>&1; then
    alias cat="bat --paging=never"
    alias batp="bat"
fi

command -v rg >/dev/null 2>&1 && alias grep="rg"

alias zshconfig="$EDITOR ~/.zshrc"
alias omzconfig="$EDITOR ~/.oh-my-zsh"
alias reload="exec zsh"

alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

alias mkdir="mkdir -pv"

alias ip="ip -color"
alias df="df -h"
alias free="free -h"

if command -v zoxide &>/dev/null; then
    eval "$(zoxide init zsh)"
fi
# >>> miyu zsh hook >>>
[ -r "$HOME/.config/miyu/shell/zsh-hook.zsh" ] && source "$HOME/.config/miyu/shell/zsh-hook.zsh"
# <<< miyu zsh hook <<<

# kimi-code
[ -d "$HOME/.kimi-code/bin" ] && export PATH="$HOME/.kimi-code/bin:$PATH"
