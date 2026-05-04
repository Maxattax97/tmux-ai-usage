#!/bin/sh

CURRENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Expose a tmux option that can be expanded with #{E:@ai_usage}.
tmux set-option -gq "@ai_usage" "#($CURRENT_DIR/scripts/ai-usage)"
