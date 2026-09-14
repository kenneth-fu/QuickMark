#!/bin/bash
# Runs generate_project.rb against the xcodeproj gem bundled with Homebrew's
# CocoaPods, so it does not matter which Ruby happens to be on PATH.
set -euo pipefail

COCOAPODS_LIBEXEC=$(find /opt/homebrew/Cellar/cocoapods -maxdepth 2 -name libexec -type d 2>/dev/null | sort | tail -1)

if [[ -z "$COCOAPODS_LIBEXEC" ]]; then
  echo "Could not find the CocoaPods libexec directory." >&2
  echo "Install it with: brew install cocoapods" >&2
  exit 1
fi

RUBY=$(find "$COCOAPODS_LIBEXEC/.." -maxdepth 1 -name 'ruby*' 2>/dev/null | head -1)
[[ -x "${RUBY:-}" ]] || RUBY=/opt/homebrew/opt/ruby/bin/ruby
[[ -x "$RUBY" ]] || RUBY=/usr/bin/ruby

cd "$(dirname "$0")"
GEM_HOME="$COCOAPODS_LIBEXEC" exec "$RUBY" generate_project.rb "$@"
