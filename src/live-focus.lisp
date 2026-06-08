;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; live-focus.lisp --- Real libinput events driving the focus logic
;;;
;;; MIT license.
;;;
;;; RUN-FOCUS proves the focus logic with scripted cursor warps.  This wires the
;;; SAME logic (UPDATE-POINTER-FOCUS / FOCUS-KEYBOARD) to *real* input from
;;; libinput: a multi-backend combines a headless backend (for an output + a
;;; client to focus) with a libinput backend (for actual devices).  Each device
;;; event is a Lisp closure inside wlroots' event loop:
;;;
;;;   cursor motion -> move the cursor, then UPDATE-POINTER-FOCUS at its position
;;;   button press  -> click-to-focus: give the pointer-focused surface the
;;;                    keyboard focus, and forward the button
;;;   key           -> forward to the keyboard-focused surface
;;;
;;; With no physical devices on the Pi, drive it by injecting synthetic events
;;; through /dev/uinput (tools/inject.c), exactly as RUN-INPUT does.  Needs a
;;; session (libseat), so run as root.

(in-package #:lispwc)

(defvar *warped* nil)
(defvar *live-key-frame* nil)

(defun cursor-xy ()
  (values (cffi:foreign-slot-value *focus-cursor* '(:struct wlr-cursor) 'x)
          (cffi:foreign-slot-value *focus-cursor* '(:struct wlr-cursor) 'y)))

(defun live-on-cursor-motion (listener data)
  "Real relative pointer motion: move the cursor, then refocus under it."
  (declare (ignore listener))
  (let ((dx (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-x))
        (dy (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-y)))
    (wlr-cursor-move *focus-cursor* (cffi:null-pointer) dx dy)
    (multiple-value-bind (x y) (cursor-xy)
      (let ((surf (update-pointer-focus x y *frames*)))
        (format t "~&motion -> cursor (~,0F,~,0F)  pointer-focus=~:[none~;surface~]~@[ MATCH~]~%"
                x y (and surf (not (cffi:null-pointer-p surf)))
                (and surf *client-surface* (cffi:pointer-eq surf *client-surface*)))
        (finish-output)))))

(defun live-on-cursor-button (listener data)
  "Real button: on press, focus the keyboard on the surface under the cursor."
  (declare (ignore listener))
  (let ((btn   (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'button))
        (state (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'state)))
    (when (= state 1)
      (let ((surf (seat-focus)))            ; whatever the pointer is currently over
        (unless (cffi:null-pointer-p surf)
          (focus-keyboard surf)
          (format t "~&button ~D press -> keyboard focus set~@[ MATCH~]~%"
                  btn (cffi:pointer-eq (seat-kbd-focus) surf))
          (finish-output))))
    (wlr-seat-pointer-notify-button *seat-f* *frames* btn state)))

(defun live-on-key (listener data)
  "Real key: forward it to the keyboard-focused surface."
  (declare (ignore listener))
  (let ((kc    (cffi:foreign-slot-value data '(:struct wlr-keyboard-key-event) 'keycode))
        (state (cffi:foreign-slot-value data '(:struct wlr-keyboard-key-event) 'state)))
    (wlr-seat-keyboard-notify-key *seat-f* *frames* kc state)
    (when (= state 1) (setf *live-key-frame* *frames*))
    (format t "~&key ~D ~A -> forwarded to keyboard-focused surface~@[ (none focused!)~]~%"
            kc (if (= state 1) "press" "release")
            (cffi:null-pointer-p (seat-kbd-focus)))
    (finish-output)))

(defun live-on-new-input (listener data)
  (declare (ignore listener))
  (let ((type (cffi:foreign-slot-value data '(:struct wlr-input-device) 'type)))
    (case type
      ;; the wlr_cursor aggregates every pointer device into one signal set, so
      ;; its motion/button listeners are wired once in RUN-LIVE-FOCUS, not here
      (1 (wlr-cursor-attach-input-device *focus-cursor* data)
         (format t "~&new_input: pointer -> attached to cursor~%"))
      (0 (let ((kbd (wlr-keyboard-from-input-device data)))
           (wlr-seat-set-keyboard *seat-f* kbd)
           (add-listener (cffi:foreign-slot-pointer kbd '(:struct wlr-keyboard) 'key)
                         #'live-on-key))
         (format t "~&new_input: keyboard -> key handler wired~%")))
    (finish-output)))

(defun live-on-new-output (listener data)
  (declare (ignore listener))
  (setf *output* data)
  (wlr-output-init-render *output* *allocator* *renderer*)
  (cffi:with-foreign-object (state '(:struct wlr-output-state))
    (wlr-output-state-init state)
    (wlr-output-state-set-enabled state t)
    (wlr-output-state-set-custom-mode state 1280 720 60000)
    (wlr-output-commit-state *output* state)
    (wlr-output-state-finish state))
  (setf *scene-output* (wlr-scene-output-create *scene* *output*))
  (add-listener (cffi:foreign-slot-pointer *output* '(:struct wlr-output) 'frame)
                #'live-on-frame)
  (wlr-output-schedule-frame *output*))

(defun live-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  ;; once the client is mapped, place the cursor over its window so the injected
  ;; relative motion lands on it (the window is at (100,100))
  (when (and *mappedp* (not *warped*))
    (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 120d0 120d0)
    (setf *warped* t)
    (format t "~&cursor placed over window at (120,120); waiting for real input~%")
    (finish-output))
  ;; wrap up a little after the last key, or on a backstop
  (cond ((and *live-key-frame* (> *frames* (+ *live-key-frame* 8)))
         (wl-display-terminate *display*))
        ((> *frames* 900)
         (format t "~&(no input arrived within the time budget)~%")
         (wl-display-terminate *display*)))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun run-live-focus (&key (injector "/tmp/inject") (client "weston-simple-shm")
                            (verbosity 1))
  "Combine a headless output with a libinput backend; host CLIENT, then let real
device events (injected via INJECTOR) drive pointer + keyboard focus."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *client-surface* nil *mappedp* nil *warped* nil *live-key-frame* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((cproc nil) (iproc nil))
    (unwind-protect
         (let* ((loop      (wl-display-get-event-loop *display*))
                (session   (wlr-session-create loop))
                (headless  (wlr-headless-backend-create loop))
                (libinput  (wlr-libinput-backend-create session))
                (multi     (wlr-multi-backend-create loop)))
           (when (cffi:null-pointer-p session) (error "wlr_session_create failed (need root?)"))
           (when (cffi:null-pointer-p libinput) (error "wlr_libinput_backend_create failed"))
           (wlr-multi-backend-add multi headless)
           (wlr-multi-backend-add multi libinput)
           (setf *renderer*  (wlr-renderer-autocreate multi)
                 *allocator* (wlr-allocator-autocreate multi *renderer*)
                 *scene*     (wlr-scene-create))
           (wlr-renderer-init-wl-display *renderer* *display*)
           (wlr-compositor-create *display* 6 *renderer*)
           (wlr-subcompositor-create *display*)
           (wlr-data-device-manager-create *display*)
           (setf *seat-f* (wlr-seat-create *display* "seat0"))
           (wlr-seat-set-capabilities
            *seat-f* (logior +wl-seat-capability-pointer+ +wl-seat-capability-keyboard+))
           (setf *focus-cursor* (wlr-cursor-create))
           ;; wire the cursor's aggregate motion/button signals once
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'motion)
                         #'live-on-cursor-motion)
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'button)
                         #'live-on-cursor-button)
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'focus-on-new-toplevel))
           ;; the multi-backend re-emits its sub-backends' new_input/new_output
           (add-listener (cffi:foreign-slot-pointer multi '(:struct wlr-backend) 'new-output)
                         #'live-on-new-output)
           (add-listener (cffi:foreign-slot-pointer multi '(:struct wlr-backend) 'new-input)
                         #'live-on-new-input)
           (unless (wlr-backend-start multi) (error "backend start failed"))
           (let ((out (wlr-headless-add-output headless 1280 720)))
             (let ((layout (wlr-output-layout-create *display*)))
               (wlr-output-layout-add-auto layout out)
               (wlr-cursor-attach-output-layout *focus-cursor* layout)))
           (let ((socket (wl-display-add-socket-auto *display*)))
             (format t "~&socket ~A; launching ~A~%" socket client) (finish-output)
             (setf cproc (uiop:launch-program
                          (list "/bin/sh" "-c"
                                (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                          :output :interactive :error-output :interactive)))
           (when injector
             (format t "~&launching injector ~A~%" injector) (finish-output)
             (setf iproc (uiop:launch-program (list injector)
                                              :output :interactive :error-output :interactive)))
           (wl-display-run *display*))
      (when iproc (ignore-errors (uiop:terminate-process iproc :urgent t)))
      (when cproc (ignore-errors (uiop:terminate-process cproc :urgent t)))
      (free-listeners)
      (wl-display-destroy *display*)))
  (format t "~&done.~%"))
