;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; stack.lisp --- Click-to-raise and window stacking
;;;
;;; MIT license.
;;;
;;; A small window registry (one WIN per mapped toplevel) plus the two
;;; primitives a stacking compositor needs: SURFACE-AT (what surface is on top
;;; at a point) and RAISE-WINDOW-AT (raise the window under a point to the top
;;; of the scene graph, wlr_scene_node_raise_to_top).  RUN-STACK hosts two
;;; overlapping windows and proves it: the topmost surface in the overlap
;;; changes after a click raises the lower window.

(in-package #:lispwc)

(defstruct (win (:constructor make-win))
  label surface tree toplevel x y w h
  listeners)                    ; this window's wl_listeners, for teardown

(defvar *wins* nil)             ; mapped windows, most-recently-pushed first
(defvar *next-idx* 0)
(defvar *both-frame* nil)

(defun forget-window (w)
  "A window's surface is being destroyed: unlink all of its listeners now (while
its signals are still valid) -- the trampolines are freed later by
REAP-LISTENERS -- and drop it from the window list."
  (dolist (l (win-listeners w)) (unlink-listener l))
  (setf (win-listeners w) nil
        *wins* (remove w *wins*)))

(defun surface-at (lx ly)
  "The wlr_surface of the topmost window at (LX,LY), or a NULL pointer."
  (cffi:with-foreign-objects ((nx :double) (ny :double))
    (let ((node (wlr-scene-node-at *scene* (float lx 1d0) (float ly 1d0) nx ny)))
      (if (or (cffi:null-pointer-p node)
              (/= (cffi:foreign-slot-value node '(:struct wlr-scene-node) 'type)
                  +scene-node-buffer+))
          (cffi:null-pointer)
          (let ((ss (wlr-scene-surface-try-from-buffer (wlr-scene-buffer-from-node node))))
            (if (cffi:null-pointer-p ss)
                (cffi:null-pointer)
                (cffi:foreign-slot-value ss '(:struct wlr-scene-surface) 'surface)))))))

(defun win-for-surface (surface)
  (and (not (cffi:null-pointer-p surface))
       (find-if (lambda (w) (let ((s (win-surface w)))
                              (and s (cffi:pointer-eq s surface))))
                *wins*)))

(defun raise-window-at (lx ly)
  "Raise the window under (LX,LY) to the top of the scene graph.  Returns it."
  (let ((w (win-for-surface (surface-at lx ly))))
    (when w (wlr-scene-node-raise-to-top (win-tree w)))
    w))

(defun top-window-at (lx ly)
  (win-for-surface (surface-at lx ly)))

(defun stack-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base))
         (idx     *next-idx*)
         (px      (+ 100 (* 150 idx)))         ; cascade so windows overlap
         (py      (+ 100 (* 150 idx)))
         (w       (make-win :label (1+ idx) :tree tree :toplevel toplevel :x px :y py)))
    (incf *next-idx*)
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
     (lambda (l d) (declare (ignore l d))
       (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
         (wlr-xdg-toplevel-set-size toplevel 0 0))))
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
     (lambda (l d) (declare (ignore l d))
       (setf (win-surface w) surface
             (win-w w) (cffi:foreign-slot-value surface '(:struct wlr-surface) 'cur-width)
             (win-h w) (cffi:foreign-slot-value surface '(:struct wlr-surface) 'cur-height))
       (wlr-scene-node-set-position tree px py)
       (push w *wins*)
       (format t "~&window ~D mapped at (~D,~D), size ~Dx~D~%"
               (win-label w) px py (win-w w) (win-h w))
       (finish-output)))))

(defun report-top (lx ly)
  (let ((w (top-window-at lx ly)))
    (format t "~&  top window at (~D,~D): ~A~%"
            lx ly (if w (format nil "window ~D" (win-label w)) "none"))
    (finish-output)
    w))

(defun stack-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  ;; once both windows are up, script: see who's on top in the overlap, click
  ;; the exposed part of the lower window to raise it, then look again.
  (when (and (null *both-frame*) (>= (length *wins*) 2))
    (setf *both-frame* *frames*))
  (when *both-frame*
    (let ((step (- *frames* *both-frame*)))
      (case step
        ;; window 1 at (100,100), window 2 at (250,250); overlap ~ (250,250)-(350,350)
        (8  (format t "~&before raise:~%")
            (report-top 300 300))             ; expect window 2 (created last => on top)
        (16 (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 150d0 150d0)  ; window 1 only
            (let ((r (raise-window-at 150 150)))
              (format t "~&click at (150,150) -> raised ~A~%"
                      (if r (format nil "window ~D" (win-label r)) "nothing"))
              (finish-output)))
        (24 (format t "~&after raise:~%")
            (report-top 300 300))             ; expect window 1 now (was raised)
        (32 (wl-display-terminate *display*)))))
  (when (> *frames* 600) (wl-display-terminate *display*))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun stack-on-new-output (listener data)
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
                #'stack-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-stack (&key (client "weston-simple-shm") (verbosity 1))
  "Host two overlapping windows; click the exposed part of the lower one and
confirm it is raised above the other (the topmost surface in the overlap flips)."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *wins* nil *next-idx* 0 *both-frame* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((procs nil))
    (unwind-protect
         (let* ((loop    (wl-display-get-event-loop *display*))
                (backend (wlr-headless-backend-create loop)))
           (setf *renderer*  (wlr-renderer-autocreate backend)
                 *allocator* (wlr-allocator-autocreate backend *renderer*)
                 *scene*     (wlr-scene-create))
           (wlr-renderer-init-wl-display *renderer* *display*)
           (wlr-compositor-create *display* 6 *renderer*)
           (wlr-subcompositor-create *display*)
           (wlr-data-device-manager-create *display*)
           (setf *seat-f* (wlr-seat-create *display* "seat0"))
           (wlr-seat-set-capabilities *seat-f* +wl-seat-capability-pointer+)
           (setf *focus-cursor* (wlr-cursor-create))
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'stack-on-new-toplevel))
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'stack-on-new-output)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (let ((out (wlr-headless-add-output backend 1280 720)))
             (let ((layout (wlr-output-layout-create *display*)))
               (wlr-output-layout-add-auto layout out)
               (wlr-cursor-attach-output-layout *focus-cursor* layout)))
           (let ((socket (wl-display-add-socket-auto *display*)))
             (format t "~&socket ~A; launching two ~A windows~%" socket client)
             (finish-output)
             (dotimes (i 2)
               (push (uiop:launch-program
                      (list "/bin/sh" "-c"
                            (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                      :output :interactive :error-output :interactive)
                     procs)))
           (wl-display-run *display*))
      (dolist (p procs) (ignore-errors (uiop:terminate-process p :urgent t)))
      (free-listeners)
      (wl-display-destroy *display*)))
  (format t "~&done.~%"))
