# lispwc

A minimal **Wayland compositor in Common Lisp**, built on
[wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) — where every
`wl_listener` callback is a Lisp closure created with
[cffi-callback-closures](https://github.com/lispnik/cffi-callback-closures).

> **Why this exists:** lispwc is primarily a *workout* for
> [cffi-callback-closures](https://github.com/lispnik/cffi-callback-closures) —
> a compositor is the densest web of context-carrying C callbacks there is, so
> it's a great stress test for "every `wl_listener` is a Lisp closure." It is
> not meant as a production toolkit. If you want to actually *use* Wayland from
> Common Lisp, **[cl-wayland](https://github.com/malcolmstill/cl-wayland)** is
> likely the more practical starting point.

A compositor is a dense web of `wl_listener` callbacks (`new_output`, surface
`map`/`commit`/`destroy`, input events…). In C the handler recovers its context
with `wl_container_of`, because C has no closures. Here each listener's `notify`
is a Lisp closure that simply *closes over* its context — the same win as
[lispfs](https://github.com/lispnik/lispfs), but for the densest callback graph
there is.

## What works — verified on a Raspberry Pi 4 (Debian 13, wlroots 0.19, SBCL)

**Headless bring-up** — `(run-headless)`: headless backend + one output + a
`wlr_scene` solid-color frame loop, with `new_output`/`frame` as Lisp closures.

```
new_output: configured 1280x720, commit=T
committed 12 frames; terminating
done. frames committed: 12        ; exit 0, clean teardown
```

**Rendering the right pixels** — `(render-color-test)`: render a blue rect into
a CPU buffer via a `wlr_render_pass` and read pixel (0,0) back.

```
read-back pixel (0,0): R=25 G=51 B=115  (asked 26 51 115)   ; rounding only
```

**Hosting a real client (xdg-shell)** — `(run-with-client)`: open a Wayland
socket, launch a real client, host its window in the scene; the `new_toplevel`
/ surface `commit` / `map` handlers are closures.

```
compositor socket: wayland-0
launching client: weston-simple-shm
new_toplevel: a client created a window
*** client surface MAPPED -- hosting a real Wayland window ***
done. surfaces mapped: 1
```

**Multiple windows + placement + a seat** — `(run-multi :clients 2)`: host
several clients at once, tiling each at its own position (each window placed in
its own `map` closure), and advertise a `wl_seat`.

```
new_toplevel #1 -> window mapped, placed at (0,40); total 1
new_toplevel #2 -> window mapped, placed at (340,40); total 2
done. windows hosted: 2
```

**Driving the real display (DRM/KMS)** — `(run-drm)` via
`wlr_backend_autocreate`. Run as root on the Pi over SSH it got DRM master via
libseat's **builtin** backend, brought up the **real V3D GPU with a GLES2
renderer**, and enumerated the actual HDMI connectors:

```
[libseat] Seat opened with backend 'builtin'
[backend/drm] Initializing DRM backend for /dev/dri/card1 (vc4)
[render/gles2] Creating GLES2 renderer ... GL renderer: V3D 4.2.14.0
[backend/drm] Found connector 'HDMI-A-1'
```

The full init path works from Lisp; it fills the screen blue once a monitor is
attached (the Pi under test had both HDMI connectors `disconnected`, so
`new_output` never fired — plug in a display and rerun).

**Input events (`wlr_cursor` + libinput)** — `(run-input)`: bring up the
libinput backend, attach pointer devices to a `wlr_cursor`, add a key listener
per keyboard. With no physical mouse/keyboard on the Pi, it's verified by
**injecting synthetic events through `/dev/uinput`** (`tools/inject.c`) —
libinput treats the virtual device exactly like a real one:

```
new_input: type 1 (pointer) -> attached pointer to cursor
pointer motion d=(15.0,10.0) ...      (first deltas ramped by libinput accel)
pointer button 272 pressed/released   (BTN_LEFT)
key keycode 30 pressed/released       (KEY_A)
```

So libinput → `wlr_cursor`/`wlr_keyboard` → Lisp closure is proven end-to-end.

**Cursor + keyboard focus** — `(run-focus)`. Pointer focus:
`update-pointer-focus` finds the scene node under the cursor
(`wlr_scene_node_at`), resolves it to a `wlr_surface`, and gives it the seat's
pointer focus (enter + motion), clearing focus over empty space. Keyboard
focus: click-to-focus gives the surface the seat's keyboard focus
(`wlr_seat_keyboard_notify_enter`) and forwards keys to it
(`wlr_seat_keyboard_notify_key`). Verified by hosting a client and warping the
cursor on/off its window, reading back `seat->pointer_state.focused_surface` and
`seat->keyboard_state.focused_surface`:

```
client mapped at (100,100)
INSIDE  cursor (150,150): node-surface=yes  seat-focus=set   MATCH
OUTSIDE cursor (5,5):     node-surface=none seat-focus=NULL  MATCH
  sent BTN_LEFT press to focused surface
  keyboard focus -> set  MATCH
  forwarded key 30 (KEY_A) to keyboard-focused surface
  keyboard focus cleared -> NULL (ok)
```

Together these exercise the whole chain from Lisp: backend → event loop →
output → `wlr_scene` rendering (correct pixels) → a real client connecting over
the protocol and being composited → input from real devices — **all of it
driven by `wl_listener` closures executing inside wlroots' event loop**.

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
# headless solid-color frame loop
sbcl --eval '(asdf:load-system :lispwc)' --eval '(lispwc:run-headless :frames 30)'

# render a color and read the pixel back -- pixman => CPU-mappable buffer
WLR_RENDERER=pixman sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:render-color-test)'

# host a real Wayland client; needs XDG_RUNTIME_DIR for the socket
export XDG_RUNTIME_DIR=$(mktemp -d)
WLR_RENDERER=pixman sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-with-client :client "weston-simple-shm")'

# multiple tiled windows
WLR_RENDERER=pixman sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-multi :clients 2)'

# input events via libinput (inject synthetic events with tools/inject.c)
cc -O2 -o /tmp/inject tools/inject.c
sudo env CPATH="$PWD/protocols" WLR_BACKENDS=libinput \
     sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-input :injector "/tmp/inject")'

# drive the real monitor -- needs DRM master, so run as root (or on the
# console) with a display plugged in:
sudo env CPATH="$PWD/protocols" WLR_BACKENDS=drm \
     sbcl --eval '(asdf:load-system :lispwc)' --eval '(lispwc:run-drm)'
```

(Force software rendering with `WLR_RENDERER=pixman` when there's no usable GPU
display; it's also what makes the readback buffer CPU-mappable.)

## Possible next steps

- wire the libinput motion/key handlers (`run-input`) into the focus logic so a
  real mouse/keyboard drives focus, not just the scripted warps
- window interaction (move/resize, drag) using the input events
- show it on a real monitor end-to-end (DRM backend + a connected display)

## License

MIT.
