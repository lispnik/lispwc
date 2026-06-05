;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; input.lisp --- multiple windows, placement, and a seat
;;;
;;; MIT license.
;;;
;;; Hosts several clients at once, tiling each at a distinct position, and
;;; advertises a wl_seat (pointer + keyboard) so input-capable clients can bind
;;; it.  Each window's placement is done in its own map closure -- the scene
;;; tree for that window is captured lexically.  (Real input *events* need
;;; physical devices.)

(in-package #:lispwc)

(defvar *seat* nil)
(defvar *target-clients* 1)
(defvar *placed* 0)

(defun multi-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (cond
    ((and (>= *xdg-mapped* *target-clients*) *frames-at-map*
          (>= *frames* (+ *frames-at-map* 8)))
     (format t "~&hosted ~D windows; terminating~%" *xdg-mapped*) (finish-output)
     (wl-display-terminate *display*))
    ((>= *frames* *timeout-frames*)
     (format t "~&timeout; mapped ~D/~D~%" *xdg-mapped* *target-clients*) (finish-output)
     (wl-display-terminate *display*))
    (t (wlr-output-schedule-frame *output*))))

(defun multi-on-new-output (listener data)
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
                #'multi-on-frame)
  (wlr-output-schedule-frame *output*))

(defun multi-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base)))  ; this window's node
    (format t "~&new_toplevel #~D~%" (1+ *xdg-mapped*)) (finish-output)
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
     (lambda (l d) (declare (ignore l d))
       (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
         (wlr-xdg-toplevel-set-size toplevel 0 0))))
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
     (lambda (l d) (declare (ignore l d))
       (let ((x (* *placed* 340)) (y 40))
         (wlr-scene-node-set-position tree x y)   ; tree == &tree->node (offset 0)
         (incf *placed*) (incf *xdg-mapped*) (setf *frames-at-map* *frames*)
         (format t "~&  window mapped, placed at (~D,~D); total ~D~%"
                 x y *xdg-mapped*)
         (finish-output))))))

(defun run-multi (&key (clients 2) (client "weston-simple-shm") (verbosity 1)
                       (timeout-frames 600))
  "Host CLIENTS instances of CLIENT at once, tiled left-to-right.  Returns the
number of windows hosted."
  (setf *xdg-mapped* 0 *placed* 0 *frames* 0 *frames-at-map* nil *output* nil
        *scene-output* (cffi:null-pointer) *timeout-frames* timeout-frames
        *target-clients* clients)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((procs '()))
    (unwind-protect
         (let* ((loop (wl-display-get-event-loop *display*))
                (backend (wlr-headless-backend-create loop)))
           (setf *renderer*  (wlr-renderer-autocreate backend)
                 *allocator* (wlr-allocator-autocreate backend *renderer*)
                 *scene*     (wlr-scene-create))
           (wlr-renderer-init-wl-display *renderer* *display*)
           (wlr-compositor-create *display* 6 *renderer*)
           (wlr-subcompositor-create *display*)
           (wlr-data-device-manager-create *display*)
           (setf *seat* (wlr-seat-create *display* "seat0"))
           (wlr-seat-set-capabilities
            *seat* (logior +wl-seat-capability-pointer+ +wl-seat-capability-keyboard+))
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'multi-on-new-toplevel))
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'multi-on-new-output)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (wlr-headless-add-output backend 1280 720)
           (let ((socket (wl-display-add-socket-auto *display*)))
             (unless socket (error "add_socket_auto failed (XDG_RUNTIME_DIR?)"))
             (format t "~&socket ~A; launching ~D x ~A~%" socket clients client)
             (finish-output)
             (dotimes (i clients)
               (push (uiop:launch-program
                      (list "/bin/sh" "-c"
                            (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                      :output :interactive :error-output :interactive)
                     procs)))
           (format t "~&running event loop...~%") (finish-output)
           (wl-display-run *display*))
      (dolist (p procs) (ignore-errors (uiop:terminate-process p :urgent t)))
      (free-listeners)
      (wl-display-destroy *display*)))
  (format t "~&done. windows hosted: ~D~%" *xdg-mapped*)
  *xdg-mapped*)
