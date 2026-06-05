#!/bin/sh
# Generate the server-side xdg-shell protocol header that wlroots' public
# headers (<wlr/types/wlr_xdg_shell.h>) #include but Debian doesn't ship.
#
# Run once before building, then build with this dir on the include path:
#
#   ./protocols/generate.sh
#   CPATH="$PWD/protocols" sbcl --eval '(asdf:load-system :lispwc)' ...
#
set -e
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"
wayland-scanner server-header "$xml" "$dir/xdg-shell-protocol.h"
echo "generated $dir/xdg-shell-protocol.h"
