;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; wlroots.lisp --- wlroots 0.19 bindings (the subset we use)
;;;
;;; MIT license.

(in-package #:lispwc)

(cffi:define-foreign-library libwlroots
  (:unix (:or "libwlroots-0.19.so.19" "libwlroots-0.19.so" "libwlroots-0.19.so.0"))
  (t (:default "libwlroots-0.19")))
(cffi:use-foreign-library libwlroots)

;; logging
(cffi:defcfun ("wlr_log_init" wlr-log-init) :void
  (verbosity :int) (callback :pointer))   ; verbosity: 0 silent 1 error 2 info 3 debug

;; backend (headless, no session/DRM needed)
(cffi:defcfun ("wlr_headless_backend_create" wlr-headless-backend-create) :pointer
  (loop :pointer))
(cffi:defcfun ("wlr_backend_start" wlr-backend-start) :bool (backend :pointer))
;; real backend (DRM/libinput, X11/Wayland nested) chosen automatically
(cffi:defcfun ("wlr_backend_autocreate" wlr-backend-autocreate) :pointer
  (loop :pointer) (session-ptr :pointer))
(cffi:defcfun ("wlr_headless_add_output" wlr-headless-add-output) :pointer
  (backend :pointer) (width :uint) (height :uint))
;; combine a headless backend (for an output) with a libinput backend (for real
;; input devices) under one multi-backend
(cffi:defcfun ("wlr_session_create" wlr-session-create) :pointer (loop :pointer))
(cffi:defcfun ("wlr_libinput_backend_create" wlr-libinput-backend-create) :pointer
  (session :pointer))
(cffi:defcfun ("wlr_multi_backend_create" wlr-multi-backend-create) :pointer (loop :pointer))
(cffi:defcfun ("wlr_multi_backend_add" wlr-multi-backend-add) :bool
  (multi :pointer) (backend :pointer))

;; renderer + allocator
(cffi:defcfun ("wlr_renderer_autocreate" wlr-renderer-autocreate) :pointer
  (backend :pointer))
(cffi:defcfun ("wlr_allocator_autocreate" wlr-allocator-autocreate) :pointer
  (backend :pointer) (renderer :pointer))
;; advertises wl_shm, linux-dmabuf, etc. so clients can supply buffers
(cffi:defcfun ("wlr_renderer_init_wl_display" wlr-renderer-init-wl-display) :bool
  (renderer :pointer) (display :pointer))

;; output
(cffi:defcfun ("wlr_output_init_render" wlr-output-init-render) :bool
  (output :pointer) (allocator :pointer) (renderer :pointer))
(cffi:defcfun ("wlr_output_state_init" wlr-output-state-init) :void (state :pointer))
(cffi:defcfun ("wlr_output_state_finish" wlr-output-state-finish) :void (state :pointer))
(cffi:defcfun ("wlr_output_state_set_enabled" wlr-output-state-set-enabled) :void
  (state :pointer) (enabled :bool))
(cffi:defcfun ("wlr_output_state_set_custom_mode" wlr-output-state-set-custom-mode) :void
  (state :pointer) (width :int32) (height :int32) (refresh :int32))  ; refresh in mHz
(cffi:defcfun ("wlr_output_preferred_mode" wlr-output-preferred-mode) :pointer
  (output :pointer))
(cffi:defcfun ("wlr_output_state_set_mode" wlr-output-state-set-mode) :void
  (state :pointer) (mode :pointer))
(cffi:defcfun ("wlr_output_commit_state" wlr-output-commit-state) :bool
  (output :pointer) (state :pointer))
(cffi:defcfun ("wlr_output_schedule_frame" wlr-output-schedule-frame) :void
  (output :pointer))
;; advertise the output as a wl_output global so clients (e.g. layer-shell
;; panels/backgrounds) can discover it
(cffi:defcfun ("wlr_output_create_global" wlr-output-create-global) :void
  (output :pointer) (display :pointer))

;; scene graph
(cffi:defcfun ("wlr_scene_create" wlr-scene-create) :pointer)
(cffi:defcfun ("wlr_scene_rect_create" wlr-scene-rect-create) :pointer
  (parent :pointer) (width :int) (height :int) (color :pointer))  ; color = float[4]
(cffi:defcfun ("wlr_scene_output_create" wlr-scene-output-create) :pointer
  (scene :pointer) (output :pointer))
(cffi:defcfun ("wlr_scene_output_commit" wlr-scene-output-commit) :bool
  (scene-output :pointer) (options :pointer))
(cffi:defcfun ("wlr_scene_output_send_frame_done" wlr-scene-output-send-frame-done) :void
  (scene-output :pointer) (now :pointer))

;; render-to-buffer + readback
(cffi:defcfun ("wlr_allocator_create_buffer" wlr-allocator-create-buffer) :pointer
  (alloc :pointer) (width :int) (height :int) (format :pointer))
(cffi:defcfun ("wlr_buffer_drop" wlr-buffer-drop) :void (buffer :pointer))
(cffi:defcfun ("wlr_renderer_begin_buffer_pass" wlr-renderer-begin-buffer-pass) :pointer
  (renderer :pointer) (buffer :pointer) (options :pointer))
(cffi:defcfun ("wlr_render_pass_add_rect" wlr-render-pass-add-rect) :void
  (pass :pointer) (options :pointer))
(cffi:defcfun ("wlr_render_pass_submit" wlr-render-pass-submit) :bool (pass :pointer))
(cffi:defcfun ("wlr_buffer_begin_data_ptr_access" wlr-buffer-begin-data-ptr-access) :bool
  (buffer :pointer) (flags :uint32) (data :pointer) (format :pointer) (stride :pointer))
(cffi:defcfun ("wlr_buffer_end_data_ptr_access" wlr-buffer-end-data-ptr-access) :void
  (buffer :pointer))
(defconstant +wlr-buffer-data-ptr-access-read+ 1)

;; compositor globals + xdg-shell
(cffi:defcfun ("wlr_compositor_create" wlr-compositor-create) :pointer
  (display :pointer) (version :uint32) (renderer :pointer))
(cffi:defcfun ("wlr_subcompositor_create" wlr-subcompositor-create) :pointer
  (display :pointer))
(cffi:defcfun ("wlr_data_device_manager_create" wlr-data-device-manager-create) :pointer
  (display :pointer))
(cffi:defcfun ("wlr_xdg_shell_create" wlr-xdg-shell-create) :pointer
  (display :pointer) (version :uint32))
(cffi:defcfun ("wlr_scene_xdg_surface_create" wlr-scene-xdg-surface-create) :pointer
  (parent :pointer) (xdg-surface :pointer))
(cffi:defcfun ("wlr_xdg_toplevel_set_size" wlr-xdg-toplevel-set-size) :uint32
  (toplevel :pointer) (width :int32) (height :int32))

;; window placement + a seat global
(cffi:defcfun ("wlr_scene_node_set_position" wlr-scene-node-set-position) :void
  (node :pointer) (x :int) (y :int))
(cffi:defcfun ("wlr_scene_node_raise_to_top" wlr-scene-node-raise-to-top) :void
  (node :pointer))
(cffi:defcfun ("wlr_scene_node_lower_to_bottom" wlr-scene-node-lower-to-bottom) :void
  (node :pointer))

;; layer-shell: panels/backgrounds anchored to screen edges
(cffi:defcfun ("wlr_layer_shell_v1_create" wlr-layer-shell-v1-create) :pointer
  (display :pointer) (version :uint32))
(cffi:defcfun ("wlr_scene_layer_surface_v1_create" wlr-scene-layer-surface-v1-create) :pointer
  (parent :pointer) (layer-surface :pointer))
;; positions the scene node per the surface's anchors/margins/exclusive-zone and
;; sends the configure; full-area is the output box, usable-area is updated
(cffi:defcfun ("wlr_scene_layer_surface_v1_configure" wlr-scene-layer-surface-v1-configure) :void
  (scene-layer-surface :pointer) (full-area :pointer) (usable-area :pointer))
(defconstant +layer-background+ 0)
(defconstant +layer-bottom+ 1)
(defconstant +layer-top+ 2)
(defconstant +layer-overlay+ 3)
(cffi:defcfun ("wlr_seat_create" wlr-seat-create) :pointer
  (display :pointer) (name :string))
(cffi:defcfun ("wlr_seat_set_capabilities" wlr-seat-set-capabilities) :void
  (seat :pointer) (capabilities :uint32))
(defconstant +wl-seat-capability-pointer+ 1)
(defconstant +wl-seat-capability-keyboard+ 2)

;; input: cursor, output layout, keyboard
(cffi:defcfun ("wlr_cursor_create" wlr-cursor-create) :pointer)
(cffi:defcfun ("wlr_cursor_attach_output_layout" wlr-cursor-attach-output-layout) :void
  (cursor :pointer) (layout :pointer))
(cffi:defcfun ("wlr_cursor_attach_input_device" wlr-cursor-attach-input-device) :void
  (cursor :pointer) (device :pointer))
(cffi:defcfun ("wlr_cursor_move" wlr-cursor-move) :void
  (cursor :pointer) (device :pointer) (delta-x :double) (delta-y :double))
(cffi:defcfun ("wlr_output_layout_create" wlr-output-layout-create) :pointer
  (display :pointer))
(cffi:defcfun ("wlr_output_layout_add_auto" wlr-output-layout-add-auto) :pointer
  (layout :pointer) (output :pointer))
(cffi:defcfun ("wlr_keyboard_from_input_device" wlr-keyboard-from-input-device) :pointer
  (device :pointer))

;; xcursor: a visible pointer image (loaded from an Xcursor theme)
(cffi:defcfun ("wlr_xcursor_manager_create" wlr-xcursor-manager-create) :pointer
  (name :string) (size :uint32))                ; name NULL -> default theme
(cffi:defcfun ("wlr_xcursor_manager_load" wlr-xcursor-manager-load) :bool
  (manager :pointer) (scale :float))
(cffi:defcfun ("wlr_cursor_set_xcursor" wlr-cursor-set-xcursor) :void
  (cursor :pointer) (manager :pointer) (name :string))
(cffi:defcfun ("wlr_cursor_set_surface" wlr-cursor-set-surface) :void
  (cursor :pointer) (surface :pointer) (hotspot-x :int32) (hotspot-y :int32))

;; cursor focus to surfaces: find the surface under the cursor + notify the seat
(defconstant +scene-node-buffer+ 2)   ; enum wlr_scene_node_type: TREE,RECT,BUFFER
(cffi:defcfun ("wlr_scene_node_at" wlr-scene-node-at) :pointer
  (node :pointer) (lx :double) (ly :double) (nx :pointer) (ny :pointer))
(cffi:defcfun ("wlr_scene_buffer_from_node" wlr-scene-buffer-from-node) :pointer
  (node :pointer))
(cffi:defcfun ("wlr_scene_surface_try_from_buffer" wlr-scene-surface-try-from-buffer) :pointer
  (buffer :pointer))
(cffi:defcfun ("wlr_cursor_warp" wlr-cursor-warp) :bool
  (cursor :pointer) (device :pointer) (lx :double) (ly :double))
(cffi:defcfun ("wlr_seat_pointer_notify_enter" wlr-seat-pointer-notify-enter) :void
  (seat :pointer) (surface :pointer) (sx :double) (sy :double))
(cffi:defcfun ("wlr_seat_pointer_notify_motion" wlr-seat-pointer-notify-motion) :void
  (seat :pointer) (time-msec :uint32) (sx :double) (sy :double))
(cffi:defcfun ("wlr_seat_pointer_clear_focus" wlr-seat-pointer-clear-focus) :void
  (seat :pointer))
(cffi:defcfun ("wlr_seat_pointer_notify_button" wlr-seat-pointer-notify-button) :uint32
  (seat :pointer) (time-msec :uint32) (button :uint32) (state :int))
;; keyboard focus
(cffi:defcfun ("wlr_seat_set_keyboard" wlr-seat-set-keyboard) :void
  (seat :pointer) (keyboard :pointer))
(cffi:defcfun ("wlr_seat_keyboard_notify_enter" wlr-seat-keyboard-notify-enter) :void
  (seat :pointer) (surface :pointer) (keycodes :pointer)
  (num-keycodes :unsigned-long) (modifiers :pointer))
(cffi:defcfun ("wlr_seat_keyboard_notify_key" wlr-seat-keyboard-notify-key) :void
  (seat :pointer) (time-msec :uint32) (key :uint32) (state :uint32))
(cffi:defcfun ("wlr_seat_keyboard_clear_focus" wlr-seat-keyboard-clear-focus) :void
  (seat :pointer))

;; clock for frame timestamps
(cffi:defcfun ("clock_gettime" clock-gettime) :int (clk-id :int) (tp :pointer))
(defconstant +clock-monotonic+ 1)
