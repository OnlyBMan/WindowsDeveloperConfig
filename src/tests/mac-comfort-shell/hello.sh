#!/usr/bin/env zsh
# Minimal hello-world for the mac-comfort-shell flow.
#
# Invoked via `wsl -d <distro> -- zsh -lc 'bash tests/mac-comfort-shell/hello.sh'`.
# Running this under zsh -lc proves that the shell this flow configures
# (zsh with the mac-comfort managed block in ~/.zprofile) at least
# dot-sources its login files without errors.
#
# Note: this flow is manual_test: true — CI does not execute this.
echo "Hello, world!"
