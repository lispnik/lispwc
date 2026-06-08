;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; move-resize.lisp --- Interactive window move/resize from real input
;;;
;;; MIT license.
;;;
;;; Classic compositor "grab" interaction, driven by libinput (same multi-backend
;;; setup as live-focus.lisp).  Press a mouse button over a window to grab it:
;;;
;;;   LEFT  button drag -> interactive MOVE: reposition the window's scene node
;;;                        to follow the cursor (purely compositor-side)
;;;   RIGHT button drag -> interactive RESIZE: recompute the geometry from the
;;;                        drag and ask the client for the new size via
;;;                        wlr_xdg_toplevel_set_size (a configure)
;;;
;;; Each grab is begun/updated/ended inside the cursor's motion/button Lisp
;;; closures.  Drive it headlessly with the synthetic pointer in
;;; tools/inject-drag.c.  Needs a session (libseat), so run as root.

(in-package #:lispwc)

(defvar *grab-mode* nil)            ; nil | :move | :resize
(defvar *grab-tree* nil)            ; the window's scene tree (node at offset 0)
(defvar *grab-toplevel* nil)        ; its wlr_xdg_toplevel
(defvar *win-x* 0) (defvar *win-y* 0)        ; current window position
(defvar *win-w* 0) (defvar *win-h* 0)        ; current window size
(defvar *grab-off-x* 0) (defvar *grab-off-y* 0)   ; move: cursor - window pos
(defvar *grab-cx* 0d0) (defvar *grab-cy* 0d0)     ; resize: cursor at grab start
(defvar *grab-sw* 0) (defvar *grab-sh* 0)         ; resize: size at grab start
(defvar *mr-done-frame* nil)

(defun node-x (node) (cffi:foreign-slot-value node '(:struct wlr-scene-node) 'x))
(defun node-y (node) (cffi:foreign-slot-value node '(:struct wlr-scene-node) 'y))

(defun mr-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base)))
    (setf *grab-toplevel* toplevel *grab-tree* tree)
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
     (lambda (l d) (declare (ignore l d))
       (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
         (wlr-xdg-toplevel-set-size toplevel 0 0))))
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
     (lambda (l d) (declare (ignore l d))
       (setf *win-x* 100 *win-y* 100
             *win-w* (cffi:foreign-slot-value surface '(:struct wlr-surface) 'cur-width)
             *win-h* (cffi:foreign-slot-value surface '(:struct wlr-surface) 'cur-height))
       (wlr-scene-node-set-position tree *win-x* *win-y*)
       (setf *client-surface* surface *mappedp* t)
       (format t "~&client mapped at (~D,~D), size ~Dx~D~%"
               *win-x* *win-y* *win-w* *win-h*)
       (finish-output)))))

(defun mr-begin-grab (mode)
  (setf *grab-mode* mode)
  (multiple-value-bind (cx cy) (cursor-xy)
    (case mode
      (:move   (setf *grab-off-x* (- cx *win-x*) *grab-off-y* (- cy *win-y*))
               (format t "~&begin MOVE grab (window at ~D,~D)~%" *win-x* *win-y*))
      (:resize (setf *grab-cx* cx *grab-cy* cy *grab-sw* *win-w* *grab-sh* *win-h*)
               (format t "~&begin RESIZE grab (size ~Dx~D)~%" *win-w* *win-h*))))
  (finish-output))

(defun mr-on-cursor-motion (listener data)
  (declare (ignore listener))
  (let ((dx (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-x))
        (dy (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-y)))
    (wlr-cursor-move *focus-cursor* (cffi:null-pointer) dx dy))
  (multiple-value-bind (cx cy) (cursor-xy)
    (case *grab-mode*
      (:move
       (setf *win-x* (round (- cx *grab-off-x*)) *win-y* (round (- cy *grab-off-y*)))
       (wlr-scene-node-set-position *grab-tree* *win-x* *win-y*)
       (format t "~&move   -> window at (~D,~D)  [scene node reads (~D,~D)]~%"
               *win-x* *win-y* (node-x *grab-tree*) (node-y *grab-tree*))
       (finish-output))
      (:resize
       (setf *win-w* (max 1 (round (+ *grab-sw* (- cx *grab-cx*))))
             *win-h* (max 1 (round (+ *grab-sh* (- cy *grab-cy*)))))
       (wlr-xdg-toplevel-set-size *grab-toplevel* *win-w* *win-h*)
       (format t "~&resize -> requested ~Dx~D  [toplevel scheduled ~Dx~D]~%"
               *win-w* *win-h*
               (cffi:foreign-slot-value *grab-toplevel* '(:struct wlr-xdg-toplevel) 'sched-width)
               (cffi:foreign-slot-value *grab-toplevel* '(:struct wlr-xdg-toplevel) 'sched-height))
       (finish-output))
      (t                                  ; no grab: ordinary pointer focus
       (update-pointer-focus cx cy *frames*)))))

(defun mr-on-cursor-button (listener data)
  (declare (ignore listener))
  (let ((btn   (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'button))
        (state (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'state)))
    (cond
      ((= state 1)                        ; press: grab if a window is under the cursor
       (multiple-value-bind (cx cy) (cursor-xy)
         (when (update-pointer-focus cx cy *frames*)
           (mr-begin-grab (if (= btn 273) :resize :move)))))
      (t                                  ; release: end the grab
       (when *grab-mode*
         (format t "~&end ~A grab~%" *grab-mode*) (finish-output)
         (when (eq *grab-mode* :resize) (setf *mr-done-frame* *frames*))
         (setf *grab-mode* nil))))))

(defun mr-on-new-input (listener data)
  (declare (ignore listener))
  (let ((type (cffi:foreign-slot-value data '(:struct wlr-input-device) 'type)))
    (when (= type 1)                      ; pointer
      (wlr-cursor-attach-input-device *focus-cursor* data)
      (format t "~&new_input: pointer -> attached to cursor~%") (finish-output))))

(defun mr-on-new-output (listener data)
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
                #'mr-on-frame)
  (wlr-output-schedule-frame *output*))

(defun mr-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (when (and *mappedp* (not *warped*))
    (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 120d0 120d0)
    (setf *warped* t)
    (format t "~&cursor placed over window at (120,120); waiting for real input~%")
    (finish-output))
  (cond ((and *mr-done-frame* (> *frames* (+ *mr-done-frame* 8)))
         (wl-display-terminate *display*))
        ((> *frames* 900)
         (format t "~&(no input arrived within the time budget)~%")
         (wl-display-terminate *display*)))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun run-move-resize (&key (injector "/tmp/inject-drag") (client "weston-simple-shm")
                             (verbosity 1))
  "Host CLIENT, then let real button-drags (injected via INJECTOR) move and
resize its window."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *client-surface* nil *mappedp* nil *warped* nil
        *grab-mode* nil *grab-tree* nil *grab-toplevel* nil *mr-done-frame* nil)
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
           (wlr-seat-set-capabilities *seat-f* +wl-seat-capability-pointer+)
           (setf *focus-cursor* (wlr-cursor-create))
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'motion)
                         #'mr-on-cursor-motion)
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'button)
                         #'mr-on-cursor-button)
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'mr-on-new-toplevel))
           (add-listener (cffi:foreign-slot-pointer multi '(:struct wlr-backend) 'new-output)
                         #'mr-on-new-output)
           (add-listener (cffi:foreign-slot-pointer multi '(:struct wlr-backend) 'new-input)
                         #'mr-on-new-input)
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
