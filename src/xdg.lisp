;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; xdg.lisp --- Milestone 2: host a real Wayland client via xdg-shell
;;;
;;; MIT license.
;;;
;;; Brings up the compositor with a wl_compositor + xdg_shell, opens a socket,
;;; launches a real Wayland client, and hosts its window in the scene.  The
;;; new_toplevel / surface-commit / surface-map handlers are Lisp closures.

(in-package #:lispwc)

(defvar *xdg-mapped* 0)
(defvar *frames-at-map* nil)
(defvar *client-proc* nil)
(defvar *timeout-frames* 600)

(defun m2-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (cond
    ((and *frames-at-map* (>= *frames* (+ *frames-at-map* 8)))
     (format t "~&hosted the client for a few frames; terminating~%") (finish-output)
     (wl-display-terminate *display*))
    ((>= *frames* *timeout-frames*)
     (format t "~&timeout (~D frames) with no client map; terminating~%" *frames*)
     (finish-output)
     (wl-display-terminate *display*))
    (t (wlr-output-schedule-frame *output*))))

(defun m2-on-new-output (listener data)
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
                #'m2-on-frame)
  (wlr-output-schedule-frame *output*))

(defun m2-on-new-toplevel (listener data)
  "A client created an xdg toplevel.  Add it to the scene and wire its commit
and map listeners as closures over this toplevel/surface."
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface)))
    (format t "~&new_toplevel: a client created a window~%") (finish-output)
    (wlr-scene-xdg-surface-create *scene* base)   ; scene ptr == &scene->tree
    ;; on the initial commit, send a configure so the client can attach a buffer
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
     (lambda (l d) (declare (ignore l d))
       (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
         (wlr-xdg-toplevel-set-size toplevel 0 0))))
    ;; map: the window is now showing
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
     (lambda (l d) (declare (ignore l d))
       (incf *xdg-mapped*)
       (setf *frames-at-map* *frames*)
       (format t "~&*** client surface MAPPED -- hosting a real Wayland window ***~%")
       (finish-output)))))

(defun run-with-client (&key (client "weston-simple-shm") (verbosity 1)
                             (timeout-frames 600))
  "Run the compositor, launch CLIENT against its socket, and host the client's
window.  Returns the number of surfaces mapped."
  (setf *xdg-mapped* 0 *frames* 0 *frames-at-map* nil *output* nil
        *scene-output* (cffi:null-pointer) *timeout-frames* timeout-frames)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (unwind-protect
       (let* ((loop (wl-display-get-event-loop *display*))
              (backend (wlr-headless-backend-create loop)))
         (when (cffi:null-pointer-p backend) (error "headless backend create failed"))
         (setf *renderer*  (wlr-renderer-autocreate backend)
               *allocator* (wlr-allocator-autocreate backend *renderer*)
               *scene*     (wlr-scene-create))
         (wlr-renderer-init-wl-display *renderer* *display*)  ; wl_shm etc.
         ;; globals a client needs to bind
         (wlr-compositor-create *display* 6 *renderer*)
         (wlr-subcompositor-create *display*)
         (wlr-data-device-manager-create *display*)
         (let ((xdg (wlr-xdg-shell-create *display* 3)))
           (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                         #'m2-on-new-toplevel))
         (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                       #'m2-on-new-output)
         (unless (wlr-backend-start backend) (error "backend start failed"))
         (wlr-headless-add-output backend 1280 720)
         (let ((socket (wl-display-add-socket-auto *display*)))
           (unless socket (error "wl_display_add_socket_auto failed (XDG_RUNTIME_DIR?)"))
           (format t "~&compositor socket: ~A~%launching client: ~A~%" socket client)
           (finish-output)
           (setf *client-proc*
                 (uiop:launch-program
                  (list "/bin/sh" "-c"
                        (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                  :output t :error-output t)))
         (format t "~&running event loop...~%") (finish-output)
         (wl-display-run *display*))
    (when *client-proc* (ignore-errors (uiop:terminate-process *client-proc* :urgent t)))
    (free-listeners)
    (wl-display-destroy *display*))
  (format t "~&done. surfaces mapped: ~D~%" *xdg-mapped*)
  *xdg-mapped*)
