#!/bin/sh
# Build a standalone ./lispwc executable (an SBCL image with lispwc baked in).
#
#   ./build.sh
#   ./lispwc help
#   ./lispwc console weston-simple-shm     # needs root for DRM/libinput
#   ./lispwc headless --frames 60          # headless demos run anywhere
#
# The grovel step needs the generated protocol headers on the include path while
# compiling; the finished binary does not need them at runtime.
set -e
cd "$(CDPATH= cd "$(dirname "$0")" && pwd)"

if [ ! -f protocols/xdg-shell-protocol.h ] || \
   [ ! -f protocols/wlr-layer-shell-unstable-v1-protocol.h ]; then
    sh protocols/generate.sh
fi
export CPATH="$PWD/protocols${CPATH:+:$CPATH}"

sbcl --non-interactive \
     --eval '(require :asdf)' \
     --eval '(asdf:load-system :lispwc)' \
     --eval '(sb-ext:save-lisp-and-die "lispwc"
                 :executable t
                 :toplevel (function lispwc:main)
                 :save-runtime-options t)'

echo "built $PWD/lispwc"
