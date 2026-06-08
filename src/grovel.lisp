;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; grovel.lisp --- Struct offsets/sizes from the wlroots 0.19 + wayland headers
;;;
;;; MIT license.
;;;
;;; We only grovel the few things we touch: where to allocate a wl_listener and
;;; set its notify; the offsets of the two wl_signals we listen on
;;; (backend.events.new_output, output.events.frame); the size of
;;; wlr_output_state (we stack-allocate it); and struct timespec.

(in-package #:lispwc)

(define "WLR_USE_UNSTABLE")
(pkg-config-cflags "wlroots-0.19")
(pkg-config-cflags "wayland-server")

(include "wayland-server-core.h")
(include "wlr/backend.h")
(include "wlr/backend/headless.h")
(include "wlr/render/wlr_renderer.h")
(include "wlr/render/allocator.h")
(include "wlr/types/wlr_output.h")
(include "wlr/types/wlr_scene.h")
(include "wlr/types/wlr_compositor.h")
(include "wlr/types/wlr_xdg_shell.h")
(include "wlr/types/wlr_layer_shell_v1.h")
(include "wlr/types/wlr_cursor.h")
(include "wlr/types/wlr_output_layout.h")
(include "wlr/types/wlr_input_device.h")
(include "wlr/types/wlr_pointer.h")
(include "wlr/types/wlr_keyboard.h")
(include "wlr/util/log.h")
(include "wlr/util/box.h")
(include "wlr/render/pass.h")
(include "wlr/render/drm_format_set.h")
(include "drm_fourcc.h")
(include "time.h")

;; struct wl_listener { struct wl_list link; wl_notify_func_t notify; }
;; link is at offset 0, so &listener->link == the listener pointer.
(cstruct wl-listener "struct wl_listener"
  (notify "notify" :type :pointer))

;; A wl_signal is a single wl_list (two pointers) = 16 bytes; we size the slots
;; with :count 2 so the offsets are right and grovel's size check is happy.
(cstruct wlr-backend "struct wlr_backend"
  (new-input  "events.new_input"  :type :pointer :count 2)
  (new-output "events.new_output" :type :pointer :count 2))

(cstruct wlr-output "struct wlr_output"
  (frame  "events.frame" :type :pointer :count 2)
  (width  "width"  :type :int32)        ; current mode resolution
  (height "height" :type :int32))

;; size only (we wlr_output_state_init into a stack allocation)
(cstruct wlr-output-state "struct wlr_output_state")

(cstruct timespec "struct timespec"
  (sec  "tv_sec"  :type :long)
  (nsec "tv_nsec" :type :long))

;;; --- render-to-buffer + pixel readback ---
(cstruct wlr-drm-format "struct wlr_drm_format"
  (format    "format"    :type :uint32)
  (len       "len"       :type :unsigned-long)
  (capacity  "capacity"  :type :unsigned-long)
  (modifiers "modifiers" :type :pointer))

(cstruct wlr-render-rect-options "struct wlr_render_rect_options"
  (box-x      "box.x"      :type :int)
  (box-y      "box.y"      :type :int)
  (box-width  "box.width"  :type :int)
  (box-height "box.height" :type :int)
  (r "color.r" :type :float)
  (g "color.g" :type :float)
  (b "color.b" :type :float)
  (a "color.a" :type :float)
  (clip "clip" :type :pointer)
  (blend "blend_mode" :type :int))

(constant (+drm-format-xrgb8888+ "DRM_FORMAT_XRGB8888"))

;;; --- xdg-shell ---
(cstruct wlr-xdg-shell "struct wlr_xdg_shell"
  (new-toplevel "events.new_toplevel" :type :pointer :count 2))

(cstruct wlr-xdg-toplevel "struct wlr_xdg_toplevel"
  (base "base" :type :pointer)
  ;; the size the compositor last asked the client for (scheduled configure)
  (sched-width  "scheduled.width"  :type :int32)
  (sched-height "scheduled.height" :type :int32))

(cstruct wlr-xdg-surface "struct wlr_xdg_surface"
  (surface        "surface"        :type :pointer)
  (initial-commit "initial_commit" :type :uint8))   ; C _Bool, 1 byte

(cstruct wlr-surface "struct wlr_surface"
  (commit    "events.commit" :type :pointer :count 2)
  (map       "events.map"    :type :pointer :count 2)
  (cur-width  "current.width"  :type :int)    ; mapped size, surface-local
  (cur-height "current.height" :type :int))

;;; --- input events (wlr_cursor + libinput) ---
;; enum wlr_input_device_type: KEYBOARD=0 POINTER=1 TOUCH=2 ...
(cstruct wlr-input-device "struct wlr_input_device"
  (type "type" :type :int))

(cstruct wlr-cursor "struct wlr_cursor"
  (x "x" :type :double)
  (y "y" :type :double)
  (motion          "events.motion"          :type :pointer :count 2)
  (motion-absolute "events.motion_absolute" :type :pointer :count 2)
  (button          "events.button"          :type :pointer :count 2))

(cstruct wlr-pointer-motion-event "struct wlr_pointer_motion_event"
  (delta-x "delta_x" :type :double)
  (delta-y "delta_y" :type :double))

(cstruct wlr-pointer-button-event "struct wlr_pointer_button_event"
  (button "button" :type :uint32)
  (state  "state"  :type :int))   ; 1 = pressed

(cstruct wlr-keyboard "struct wlr_keyboard"
  (key "events.key" :type :pointer :count 2))

(cstruct wlr-keyboard-key-event "struct wlr_keyboard_key_event"
  (keycode "keycode" :type :uint32)
  (state   "state"   :type :int))   ; 1 = pressed

;;; --- cursor focus to surfaces ---
;; enum wlr_scene_node_type: TREE=0 RECT=1 BUFFER=2
(cstruct wlr-scene-node "struct wlr_scene_node"
  (type "type" :type :int)
  (x "x" :type :int)        ; position relative to parent
  (y "y" :type :int))
(cstruct wlr-scene-surface "struct wlr_scene_surface"
  (surface "surface" :type :pointer))
(cstruct wlr-seat "struct wlr_seat"
  (focused-surface     "pointer_state.focused_surface"  :type :pointer)
  (focused-client      "pointer_state.focused_client"   :type :pointer)
  (kbd-focused-surface "keyboard_state.focused_surface" :type :pointer)
  (request-set-cursor  "events.request_set_cursor"      :type :pointer :count 2))

;; a client asking to set its own pointer image (wl_pointer.set_cursor)
(cstruct wlr-seat-pointer-request-set-cursor-event
    "struct wlr_seat_pointer_request_set_cursor_event"
  (rsc-seat-client "seat_client" :type :pointer)
  (rsc-surface     "surface"     :type :pointer)   ; NULL means "hide the cursor"
  (rsc-hotspot-x   "hotspot_x"   :type :int32)
  (rsc-hotspot-y   "hotspot_y"   :type :int32))

;;; --- layer-shell (panels, backgrounds: wlr-layer-shell-unstable-v1) ---
(cstruct wlr-box "struct wlr_box"
  (bx "x" :type :int) (by "y" :type :int)
  (bw "width" :type :int) (bh "height" :type :int))

(cstruct wlr-layer-shell-v1 "struct wlr_layer_shell_v1"
  (new-surface "events.new_surface" :type :pointer :count 2))

;; enum zwlr_layer_shell_v1_layer: BACKGROUND=0 BOTTOM=1 TOP=2 OVERLAY=3
(cstruct wlr-layer-surface-v1 "struct wlr_layer_surface_v1"
  (surface        "surface"        :type :pointer)
  (output         "output"         :type :pointer)
  (namespace      "namespace"      :type :pointer)   ; char*
  (initial-commit "initial_commit" :type :uint8)
  (pending-layer  "pending.layer"  :type :int))

(cstruct wlr-scene-layer-surface-v1 "struct wlr_scene_layer_surface_v1"
  (tree "tree" :type :pointer))
