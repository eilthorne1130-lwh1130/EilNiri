export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME=""

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

source $ZSH/oh-my-zsh.sh

export PATH="$HOME/.local/bin:$PATH"

eval "$(starship init zsh)"

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

alias ls="eza"
alias ll="eza -lah"
alias la="eza -a"
alias lt="eza --tree"
alias l="eza -l"

alias cat="bat --paging=never"
alias batp="bat"

alias grep="rg"

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
[ -r "/home/eilthorne/.config/miyu/shell/zsh-hook.zsh" ] && source "/home/eilthorne/.config/miyu/shell/zsh-hook.zsh"
# <<< miyu zsh hook <<<

# kimi-code
export PATH="/home/eilthorne/.kimi-code/bin:$PATH"
