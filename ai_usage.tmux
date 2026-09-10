#!/bin/sh

CURRENT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Expose tmux options that can be expanded with #{E:@ai_usage}.
tmux set-option -gq "@ai_usage" "#($CURRENT_DIR/scripts/ai-usage)"
tmux set-option -gq "@ai_usage_active" "#($CURRENT_DIR/scripts/ai-activity status)"
