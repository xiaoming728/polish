PS1='PROMPT> '
export VISUAL=fallback-ed   # 用户原编辑器（模拟）
[[ $POLISH_VI == 1 ]] && bindkey -v
# --- polish ---
autoload -Uz edit-command-line
zle -N polish-edit-command-line edit-command-line
zstyle ':zle:polish-edit-command-line' editor polish-edit
bindkey -M emacs '^G' polish-edit-command-line
bindkey -M viins '^G' polish-edit-command-line
bindkey -M vicmd '^G' polish-edit-command-line
# --- /polish ---
