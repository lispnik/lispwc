# lispwc

A minimal **Wayland compositor in Common Lisp**, built on
[wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) — where every
`wl_listener` callback is a Lisp closure created with
[cffi-callback-closures](https://github.com/lispnik/cffi-callback-closures).

A compositor is a dense web of `wl_listener` callbacks (`new_output`, surface
`map`/`commit`/`destroy`, input events…). In C the handler recovers its context
with `wl_container_of`, because C has no closures. Here each listener's `notify`
is a Lisp closure that simply *closes over* its context — the same win as
[lispfs](https://github.com/lispnik/lispfs), but for the densest callback graph
there is.

## Status — verified on a Raspberry Pi 4 (Debian 13, wlroots 0.19, SBCL)

**M1 — headless bring-up** ✅  Headless backend + one output + a `wlr_scene`
solid-color frame loop, with `new_output`/`frame` as Lisp closures:

```
new_output: configured 1280x720, commit=T
committed 12 frames; terminating
done. frames committed: 12        ; exit 0, clean teardown
```

**M1.5 — prove it rendered** ✅  `(render-color-test)` renders a blue rect into
a CPU buffer via a `wlr_render_pass` and reads pixel (0,0) back:

```
read-back pixel (0,0): R=25 G=51 B=115  (asked 26 51 115)   ; rounding only
```

**M2 — host a real client (xdg-shell)** ✅  `(run-with-client)` opens a Wayland
socket, launches a real client, and hosts its window in the scene; the
`new_toplevel` / surface `commit` / `map` handlers are closures:

```
compositor socket: wayland-0
launching client: weston-simple-shm
new_toplevel: a client created a window
*** client surface MAPPED -- hosting a real Wayland window ***
done. surfaces mapped: 1
```

**M3 — multiple windows + placement + a seat** ✅  `(run-multi :clients 2)`
hosts several clients at once, tiling each at its own position (each window
placed in its own `map` closure), and advertises a `wl_seat`:

```
new_toplevel #1 -> window mapped, placed at (0,40); total 1
new_toplevel #2 -> window mapped, placed at (340,40); total 2
done. windows hosted: 2
```

**M4 — drive the real display (DRM/KMS)** ✅ (to the hardware boundary)
`(run-drm)` uses `wlr_backend_autocreate`. Run as root on the Pi over SSH it
got DRM master via libseat's **builtin** backend, brought up the **real V3D GPU
with a GLES2 renderer**, and enumerated the actual HDMI connectors:

```
[libseat] Seat opened with backend 'builtin'
[backend/drm] Initializing DRM backend for /dev/dri/card1 (vc4)
[render/gles2] Creating GLES2 renderer ... GL renderer: V3D 4.2.14.0
[backend/drm] Found connector 'HDMI-A-1'
```

The full init path works from Lisp; it fills the screen blue once a monitor is
attached (the Pi under test had both HDMI connectors `disconnected`, so
`new_output` never fired — plug in a display and rerun).

These prove the whole chain works from Lisp: headless backend → event loop →
output → `wlr_scene` rendering (correct pixels) → a real client connecting over
the protocol and being composited — **all of it driven by `wl_listener`
closures executing inside wlroots' event loop**.

Headless because the event loop is single-threaded: callbacks fire on the
`wl_display_run` thread (the main Lisp thread), so there's no real-time-thread
hazard — the safe, FUSE-like case. And headless needs no DRM master or seat, so
it runs over SSH with no display and no root.

## How it works

- **`src/grovel.lisp`** grovels just what we touch from the wlroots 0.19 +
  wayland headers: where to put a `wl_listener`'s `notify`, the offsets of the
  two signals we listen on (`backend.events.new_output`, `output.events.frame`),
  the size of `wlr_output_state`, and `struct timespec`.
- **`src/wayland.lisp`** binds libwayland-server and provides `add-listener` —
  `wl_signal_add` reimplemented on the exported `wl_list_insert` (the real
  `wl_signal_add` is `static inline`, so there's no symbol to call). `notify` is
  a `make-foreign-callback` closure.
- **`src/wlroots.lisp`** binds the wlroots 0.19 subset (backend, renderer,
  allocator, output state, scene).
- **`src/main.lisp`** is the flow: create display + headless backend + renderer
  + allocator + scene; on `new_output`, configure the output and add a colored
  `wlr_scene_rect`; on `frame`, commit the scene and schedule the next frame;
  stop after N.

## Requirements

Linux + **wlroots 0.19** (`libwlroots-0.19-dev`), which pulls in
wayland-server, libdrm, pixman, EGL/GLES, libinput, etc. Plus `cffi`,
`cffi-grovel`, and `cffi-callback-closures`.

## Building

wlroots' public headers `#include "xdg-shell-protocol.h"`, a wayland-scanner
output Debian doesn't ship. Generate it and put it on the compiler's include
path before building:

```sh
./protocols/generate.sh             # writes protocols/xdg-shell-protocol.h
export CPATH="$PWD/protocols"       # so cffi-grovel's compiler finds it
```

## Running

```sh
# headless solid-color frame loop (M1)
sbcl --eval '(asdf:load-system :lispwc)' --eval '(lispwc:run-headless :frames 30)'

# render a color and read the pixel back (M1.5) -- pixman => CPU-mappable buffer
WLR_RENDERER=pixman sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:render-color-test)'

# host a real Wayland client (M2); needs XDG_RUNTIME_DIR for the socket
export XDG_RUNTIME_DIR=$(mktemp -d)
WLR_RENDERER=pixman sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-with-client :client "weston-simple-shm")'

# multiple tiled windows (M3)
WLR_RENDERER=pixman sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-multi :clients 2)'

# drive the real monitor (M4) -- needs DRM master, so run as root (or on the
# console) with a display plugged in:
sudo env CPATH="$PWD/protocols" WLR_BACKENDS=drm \
     sbcl --eval '(asdf:load-system :lispwc)' --eval '(lispwc:run-drm)'
```

(Force software rendering with `WLR_RENDERER=pixman` when there's no usable GPU
display; it's also what makes the M1.5 readback buffer CPU-mappable.)

## Roadmap

- **M1 — headless bring-up** ✅
- **M1.5 — render-and-readback (correct pixels)** ✅
- **M2 — `xdg-shell`: host a real Wayland client** ✅
- **M3 — multiple windows + placement + `wl_seat`** ✅
- **M4 — DRM backend on the real GPU (lights up an attached monitor)** ✅
- **next** — real input *events* via `wlr_cursor` + libinput (keyboard/pointer
  focus) once running on a console with devices

## License

MIT.
