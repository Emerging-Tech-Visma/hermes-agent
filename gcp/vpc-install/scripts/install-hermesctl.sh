#!/usr/bin/env bash
# Put `hermesctl` on your PATH. Run once, on your PC.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${HOME}/.local/bin"
ln -sf "${SELF}/hermesctl" "${HOME}/.local/bin/hermesctl"
echo "Linked ${HOME}/.local/bin/hermesctl -> ${SELF}/hermesctl"
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) echo "~/.local/bin is already on your PATH." ;;
  *) echo
     echo "~/.local/bin is NOT on your PATH. Add it:"
     echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac
echo
echo "Try:  hermesctl status"
