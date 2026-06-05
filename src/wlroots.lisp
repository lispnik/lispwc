;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; wlroots.lisp --- wlroots 0.19 bindings (the subset milestone 1 needs)
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
(cffi:defcfun ("wlr_headless_add_output" wlr-headless-add-output) :pointer
  (backend :pointer) (width :uint) (height :uint))

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
(cffi:defcfun ("wlr_output_commit_state" wlr-output-commit-state) :bool
  (output :pointer) (state :pointer))
(cffi:defcfun ("wlr_output_schedule_frame" wlr-output-schedule-frame) :void
  (output :pointer))

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

;; render-to-buffer + readback (M1.5)
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

;; M2: compositor globals + xdg-shell
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

;; clock for frame timestamps
(cffi:defcfun ("clock_gettime" clock-gettime) :int (clk-id :int) (tp :pointer))
(defconstant +clock-monotonic+ 1)
