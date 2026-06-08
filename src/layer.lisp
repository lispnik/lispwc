;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; layer.lisp --- Layer-shell: panels and backgrounds
;;;
;;; MIT license.
;;;
;;; wlr-layer-shell-unstable-v1 is the protocol panels (waybar), backgrounds
;;; (swaybg), notifications, and lock screens use to anchor surfaces to the
;;; edges of an output in one of four layers (background < bottom < top <
;;; overlay).  LAYER-ON-NEW-SURFACE handles a new layer surface: assign it our
;;; output, give it a scene node in the right z-order, and configure it to the
;;; output area (the wlr_scene helper does the anchor/margin/exclusive-zone
;;; math).  Wired into RUN-CONSOLE; verified headlessly by RUN-LAYER, which
;;; hosts swaybg as a background.

(in-package #:lispwc)

(defvar *layer-maps* 0)
(defvar *layer-done-frame* nil)

(defun %ns (layer-surf)
  (let ((p (cffi:foreign-slot-value layer-surf '(:struct wlr-layer-surface-v1) 'namespace)))
    (if (cffi:null-pointer-p p) "?" (cffi:foreign-string-to-lisp p))))

(defun layer-configure (scene-ls)
  "Configure the scene layer surface to the current output area."
  (let ((w (cffi:foreign-slot-value *output* '(:struct wlr-output) 'width))
        (h (cffi:foreign-slot-value *output* '(:struct wlr-output) 'height)))
    (cffi:with-foreign-objects ((full '(:struct wlr-box)) (usable '(:struct wlr-box)))
      (flet ((box (b x y bw bh)
               (setf (cffi:foreign-slot-value b '(:struct wlr-box) 'bx) x
                     (cffi:foreign-slot-value b '(:struct wlr-box) 'by) y
                     (cffi:foreign-slot-value b '(:struct wlr-box) 'bw) bw
                     (cffi:foreign-slot-value b '(:struct wlr-box) 'bh) bh)))
        (box full   0 0 w h)
        (box usable 0 0 w h)
        (wlr-scene-layer-surface-v1-configure scene-ls full usable)))))

(defun layer-on-new-surface (listener data)
  (declare (ignore listener))
  (let* ((layer-surf data)
         (out     (cffi:foreign-slot-value layer-surf '(:struct wlr-layer-surface-v1) 'output))
         (surface (cffi:foreign-slot-value layer-surf '(:struct wlr-layer-surface-v1) 'surface))
         (layer   (cffi:foreign-slot-value layer-surf '(:struct wlr-layer-surface-v1) 'pending-layer)))
    ;; the client may leave output NULL and let the compositor choose
    (when (cffi:null-pointer-p out)
      (setf (cffi:foreign-slot-value layer-surf '(:struct wlr-layer-surface-v1) 'output) *output*))
    (let* ((scene-ls (wlr-scene-layer-surface-v1-create *scene* layer-surf))
           (node     (cffi:foreign-slot-value scene-ls '(:struct wlr-scene-layer-surface-v1) 'tree)))
      ;; coarse z-order: background/bottom behind the windows, top/overlay above
      (if (<= layer +layer-bottom+)
          (wlr-scene-node-lower-to-bottom node)
          (wlr-scene-node-raise-to-top node))
      (add-listener
       (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
       (lambda (l d) (declare (ignore l d)) (layer-configure scene-ls)))
      (add-listener
       (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
       (lambda (l d) (declare (ignore l d))
         (incf *layer-maps*)
         (when (null *layer-done-frame*) (setf *layer-done-frame* *frames*))
         (format t "~&layer surface MAPPED: namespace=~A layer=~D~%" (%ns layer-surf) layer)
         (finish-output)))
      (format t "~&new layer surface: namespace=~A layer=~D~%" (%ns layer-surf) layer)
      (finish-output))))

;;; --- headless verification: host swaybg as a background ---

(defun layer-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (cond ((and *layer-done-frame* (> *frames* (+ *layer-done-frame* 4)))
         (wl-display-terminate *display*))
        ((> *frames* 400)
         (format t "~&(no layer surface mapped)~%")
         (wl-display-terminate *display*)))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun layer-on-new-output (listener data)
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
                #'layer-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-layer (&key (client "swaybg -c 224488") (verbosity 1))
  "Bring up layer-shell and host CLIENT (swaybg, a background) to confirm a
layer surface is configured to the output area and maps."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *layer-maps* 0 *layer-done-frame* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((proc nil))
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
           (let ((layer-shell (wlr-layer-shell-v1-create *display* 4)))
             (add-listener (cffi:foreign-slot-pointer layer-shell '(:struct wlr-layer-shell-v1) 'new-surface)
                           #'layer-on-new-surface))
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'layer-on-new-output)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (let ((out (wlr-headless-add-output backend 1280 720)))
             (wlr-output-create-global out *display*))   ; so swaybg can find it
           (let ((socket (wl-display-add-socket-auto *display*)))
             (format t "~&socket ~A; launching ~A~%" socket client) (finish-output)
             (setf proc (uiop:launch-program
                         (list "/bin/sh" "-c"
                               (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                         :output :interactive :error-output :interactive)))
           (wl-display-run *display*))
      (when proc (ignore-errors (uiop:terminate-process proc :urgent t)))
      (free-listeners)
      (wl-display-destroy *display*)))
  (format t "~&done. layer surfaces mapped: ~D~%" *layer-maps*))
