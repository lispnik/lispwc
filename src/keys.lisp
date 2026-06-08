;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; keys.lisp --- Headless verification of the compositor keybindings
;;;
;;; MIT license.
;;;
;;; RUN-CONSOLE's keybindings (Alt+Tab cycle, Alt+F4 close, Alt+Esc quit) need a
;;; real keyboard, so they can't be driven headlessly alone.  RUN-KEYS brings up
;;; the same console handlers on a headless-output + libinput multi-backend,
;;; hosts two windows, and is driven by the synthetic keyboard in
;;; tools/inject-keys.c.  Run as root (libinput needs a session).

(in-package #:lispwc)

(defun keys-on-frame (listener data)
  (declare (ignore listener data))
  (reap-listeners)
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (when (> *frames* 1500)                  ; backstop; Alt+Esc normally ends it
    (format t "~&(timed out before Alt+Esc)~%") (finish-output)
    (wl-display-terminate *display*))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun keys-on-new-output (listener data)
  (declare (ignore listener))
  (setf *output* data)
  (wlr-output-init-render *output* *allocator* *renderer*)
  (cffi:with-foreign-object (state '(:struct wlr-output-state))
    (wlr-output-state-init state)
    (wlr-output-state-set-enabled state t)
    (wlr-output-state-set-custom-mode state 1280 720 60000)
    (wlr-output-commit-state *output* state)
    (wlr-output-state-finish state))
  (wlr-output-create-global *output* *display*)
  (let ((layout (wlr-output-layout-create *display*)))
    (wlr-output-layout-add-auto layout *output*)
    (wlr-cursor-attach-output-layout *focus-cursor* layout))
  (setf *scene-output* (wlr-scene-output-create *scene* *output*))
  (add-listener (cffi:foreign-slot-pointer *output* '(:struct wlr-output) 'frame)
                #'keys-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-keys (&key (injector "/tmp/inject-keys")
                      (clients '("weston-simple-shm" "weston-simple-shm"))
                      (verbosity 1))
  "Host two windows on a headless+libinput backend and drive the compositor
keybindings with a synthetic keyboard (INJECTOR): Alt+Tab cycles focus, Alt+F4
closes the focused window, Alt+Esc quits."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *wins* nil *next-idx* 0 *cgrab-mode* nil *cgrab-win* nil *focused-win* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((procs nil) (iproc nil))
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
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'motion)
                         #'console-on-cursor-motion)
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'button)
                         #'console-on-cursor-button)
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'console-on-new-toplevel))
           (add-listener (cffi:foreign-slot-pointer multi '(:struct wlr-backend) 'new-output)
                         #'keys-on-new-output)
           (add-listener (cffi:foreign-slot-pointer multi '(:struct wlr-backend) 'new-input)
                         #'console-on-new-input)
           (unless (wlr-backend-start multi) (error "backend start failed"))
           (wlr-headless-add-output headless 1280 720)
           (let ((socket (wl-display-add-socket-auto *display*)))
             (format t "~&socket ~A; launching ~D client(s)~%" socket (length clients))
             (finish-output)
             (dolist (c clients)
               (push (uiop:launch-program
                      (list "/bin/sh" "-c"
                            (format nil "WAYLAND_DISPLAY=~A exec ~A" socket c))
                      :output :interactive :error-output :interactive)
                     procs)))
           (when injector
             (format t "~&launching key injector ~A~%" injector) (finish-output)
             (setf iproc (uiop:launch-program (list injector)
                                              :output :interactive :error-output :interactive)))
           (wl-display-run *display*))
      (when iproc (ignore-errors (uiop:terminate-process iproc :urgent t)))
      (dolist (p procs) (ignore-errors (uiop:terminate-process p :urgent t)))
      (free-listeners)
      (wl-display-destroy *display*)))
  (format t "~&done.~%"))
