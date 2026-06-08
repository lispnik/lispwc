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

**Real input driving focus** — `(run-live-focus)`. Combines a headless backend
(for an output + a client to focus) with a **libinput** backend under one
`wlr_multi_backend`, then wires the *same* focus logic to actual device events:
cursor `motion` → `update-pointer-focus` at the cursor; button press →
click-to-focus the keyboard; `key` → forward to the keyboard-focused surface.
Driven by the synthetic `/dev/uinput` devices (`tools/inject.c`):

```
new_input: pointer -> attached to cursor
cursor placed over window at (120,120); waiting for real input
motion -> cursor (126,124)  pointer-focus=surface MATCH      (focus follows the real cursor)
motion -> cursor (185,163)  pointer-focus=surface MATCH
button 272 press -> keyboard focus set MATCH                 (real click focuses the keyboard)
key 30 press   -> forwarded to keyboard-focused surface      (real key reaches the client)
key 30 release -> forwarded to keyboard-focused surface
```

So a real mouse/keyboard → libinput → `wlr_cursor`/`wlr_keyboard` → the focus
closures → pointer + keyboard focus, end-to-end.

**Interactive window move/resize** — `(run-move-resize)`. Press a button over a
window to begin a grab, drag to update it, release to end — each step inside the
cursor's motion/button closures. **Left**-drag moves (reposition the window's
scene node to follow the cursor); **right**-drag resizes (recompute geometry and
ask the client for the new size via `wlr_xdg_toplevel_set_size`). Driven by the
synthetic pointer in `tools/inject-drag.c`:

```
client mapped at (100,100), size 250x250
begin MOVE grab (window at 100,100)
move   -> window at (104,103)  [scene node reads (104,103)]    (move tracks the drag...
move   -> window at (187,158)  [scene node reads (187,158)]     ...scene node confirms it)
end MOVE grab
begin RESIZE grab (size 250x250)
resize -> requested 259x256  [toplevel scheduled 259x256]      (resize grows the geometry...
resize -> requested 328x297  [toplevel scheduled 328x297]       ...and the configure matches)
end RESIZE grab
```

Move is fully compositor-side, so it's verified by reading the scene node's
position straight back. Resize is the compositor asking the client for a size
(a configure), verified against the toplevel's scheduled size (whether the
window's pixels follow is up to the client — `weston-simple-shm` keeps its
buffer fixed).

**Click-to-raise + window stacking** — `(run-stack)`. A small window registry
plus `raise-window-at`: resolve the surface under a point (`wlr_scene_node_at`
→ `wlr_scene_surface`) and raise its scene tree with
`wlr_scene_node_raise_to_top`. Two overlapping windows; clicking the exposed
part of the lower one raises it above the other, which is confirmed by the
topmost surface in the overlap flipping:

```
window 1 mapped at (100,100), size 250x250
window 2 mapped at (250,250), size 250x250
before raise:  top window at (300,300): window 2     (created last => on top)
click at (150,150) -> raised window 1                (clicked its exposed corner)
after raise:   top window at (300,300): window 1     (stacking order changed)
```

**The whole thing, interactive** — `(run-console)` ties the pieces together on
the *real* backend (`wlr_backend_autocreate` → DRM/KMS + libinput): pointer
focus follows the cursor, a click raises + focuses the window under it,
left-drag moves and right-drag resizes, and keys go to the focused window — see
[Running on a real console from scratch](#running-on-a-real-console-from-scratch).
On the test Pi it brought up the seat, the DRM backend, the V3D GLES2 renderer,
**wired the real input devices through the Lisp closures**, loaded an Xcursor
theme so the pointer is a real arrow (`cursor theme loaded=T`), enumerated the
HDMI connectors, and opened a socket — everything up to `new_output`, which (as
with `run-drm`) needs a connected monitor to fire.

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

# real libinput input driving focus (headless output + libinput, run as root):
cc -O2 -o /tmp/inject tools/inject.c
sudo env CPATH="$PWD/protocols" WLR_RENDERER=pixman XDG_RUNTIME_DIR=$(mktemp -d) \
     sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-live-focus :injector "/tmp/inject")'

# interactive window move/resize from real button-drags (run as root):
cc -O2 -o /tmp/inject-drag tools/inject-drag.c
sudo env CPATH="$PWD/protocols" WLR_RENDERER=pixman XDG_RUNTIME_DIR=$(mktemp -d) \
     sbcl --eval '(asdf:load-system :lispwc)' \
     --eval '(lispwc:run-move-resize :injector "/tmp/inject-drag")'

# click-to-raise + window stacking (two overlapping windows, headless)
WLR_RENDERER=pixman XDG_RUNTIME_DIR=$(mktemp -d) \
     sbcl --eval '(asdf:load-system :lispwc)' --eval '(lispwc:run-stack)'

# drive the real monitor -- needs DRM master, so run as root (or on the
# console) with a display plugged in:
sudo env CPATH="$PWD/protocols" WLR_BACKENDS=drm \
     sbcl --eval '(asdf:load-system :lispwc)' --eval '(lispwc:run-drm)'
```

(Force software rendering with `WLR_RENDERER=pixman` when there's no usable GPU
display; it's also what makes the readback buffer CPU-mappable.)

## Running on a real console from scratch

The demos above run headless over SSH. To drive a **real monitor with a real
mouse and keyboard**, run `(run-console)` from a Linux **text console** (a VT),
where it can take DRM master and open a seat. The whole interactive compositor
— pointer focus, click-to-raise + focus, left-drag move, right-drag resize, keys
to the focused window — runs there. On the Raspberry Pi 4 test box:

1. **Get to a bare VT** with nothing else owning the GPU. If a desktop or display
   manager is running, stop it (or just switch to a free VT and log in):
   ```sh
   sudo systemctl stop lightdm        # or gdm/sddm — skip if you booted to console
   sudo chvt 3                         # or press Ctrl-Alt-F3, then log in
   ```
2. **Install** wlroots 0.19 and a test client (`weston` ships `weston-simple-shm`):
   ```sh
   sudo apt install libwlroots-0.19-dev weston sbcl
   ```
3. **Generate the protocol header** and put it on the compiler's include path
   (needed the first time the grovel file compiles):
   ```sh
   cd lispwc
   ./protocols/generate.sh
   export CPATH="$PWD/protocols"
   ```
4. **Run it.** The simplest way to get DRM master + a seat is as root — wlroots'
   builtin libseat backend then opens the seat without a login session:
   ```sh
   sudo env CPATH="$PWD/protocols" XDG_RUNTIME_DIR=$(mktemp -d) \
        sbcl --eval '(asdf:load-system :lispwc)' \
             --eval '(lispwc:run-console :clients (list "weston-simple-shm" "weston-simple-shm"))'
   ```
   The monitor switches to a dim background with the client windows on it, and
   an arrow pointer (loaded from an Xcursor theme — `apt install adwaita-icon-theme`
   if you have none). Move the mouse to move the pointer; **click** a window to
   raise + focus it;
   **left-drag** to move it; **right-drag** to resize it; **type** to send keys
   to the focused window.
5. **Quit** with **Ctrl-C** (or kill SBCL from another VT). Restore your desktop
   with `sudo chvt 1` / restarting the display manager.

Notes:

- **Unprivileged instead of root:** install **seatd** (`sudo apt install seatd &&
  sudo systemctl enable --now seatd`, then add yourself to the `seat` group) or
  run under a logind login session — wlroots' session code picks either up
  automatically, no code change.
- **No `new_output`?** The monitor isn't being detected — make sure it's
  connected and powered *before* launching (KMS enumerates connectors at
  startup). This is exactly where the test Pi stopped: both its HDMI ports read
  `disconnected`, so the backend initialized fully but `new_output` never fired.
- Add `WLR_RENDERER=pixman` to force software rendering if the GPU path misbehaves.

## Possible next steps

- confirm `run-console` on a connected monitor end-to-end (the test Pi had none)
- honor client cursor requests (`wl_pointer.set_cursor`) instead of always the arrow
- xdg-popups, multiple outputs, and minimize/maximize/fullscreen requests

## License

MIT.
