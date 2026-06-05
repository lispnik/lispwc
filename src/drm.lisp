;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; drm.lisp --- Milestone 4: drive the real display via the DRM backend
;;;
;;; MIT license.
;;;
;;; Same code as the headless path, but the backend is wlr_backend_autocreate
;;; (which selects DRM/KMS on a real session), the output uses its preferred
;;; mode, and we fill the actual monitor blue for a few seconds.
;;;
;;; Requires DRM master: run on the Pi's console, or as root over SSH when no
;;; other compositor/Xorg owns the display.

(in-package #:lispwc)

(defun drm-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (if (>= *frames* *max-frames*)
      (progn (format t "~&rendered ~D frames on the display; terminating~%" *frames*)
             (finish-output)
             (wl-display-terminate *display*))
      (wlr-output-schedule-frame *output*)))

(defun drm-on-new-output (listener data)
  (declare (ignore listener))
  (setf *output* data)
  (wlr-output-init-render *output* *allocator* *renderer*)
  (cffi:with-foreign-object (state '(:struct wlr-output-state))
    (wlr-output-state-init state)
    (wlr-output-state-set-enabled state t)
    (let ((mode (wlr-output-preferred-mode *output*)))   ; real monitors have modes
      (if (cffi:null-pointer-p mode)
          (wlr-output-state-set-custom-mode state 1920 1080 0)
          (wlr-output-state-set-mode state mode)))
    (let ((ok (wlr-output-commit-state *output* state)))
      (wlr-output-state-finish state)
      (format t "~&new_output: connected display configured, commit=~A~%" ok)
      (finish-output)))
  (setf *scene-output* (wlr-scene-output-create *scene* *output*))
  ;; big rect; wlr_scene clips it to the actual output size
  (cffi:with-foreign-object (color :float 4)
    (setf (cffi:mem-aref color :float 0) 0.10 (cffi:mem-aref color :float 1) 0.20
          (cffi:mem-aref color :float 2) 0.45 (cffi:mem-aref color :float 3) 1.0)
    (wlr-scene-rect-create *scene* 8192 8192 color))
  (add-listener (cffi:foreign-slot-pointer *output* '(:struct wlr-output) 'frame)
                #'drm-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-drm (&key (frames 180) (verbosity 2))
  "Fill the real connected display blue for FRAMES frames (~3 s at 60 Hz).
Returns frames committed.  Needs DRM master (console, or root over SSH)."
  (setf *frames* 0 *max-frames* frames *output* nil *scene-output* (cffi:null-pointer))
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (unwind-protect
       (let* ((loop (wl-display-get-event-loop *display*))
              (backend (wlr-backend-autocreate loop (cffi:null-pointer))))
         (when (cffi:null-pointer-p backend)
           (error "wlr_backend_autocreate failed (no DRM master / session?)"))
         (setf *renderer*  (wlr-renderer-autocreate backend)
               *allocator* (wlr-allocator-autocreate backend *renderer*)
               *scene*     (wlr-scene-create))
         (when (cffi:null-pointer-p *renderer*)  (error "renderer autocreate failed"))
         (when (cffi:null-pointer-p *allocator*) (error "allocator autocreate failed"))
         (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                       #'drm-on-new-output)
         (unless (wlr-backend-start backend) (error "backend start failed"))
         (format t "~&DRM backend started; rendering ~D frames to the display...~%" frames)
         (finish-output)
         (wl-display-run *display*))
    (free-listeners)
    (wl-display-destroy *display*))
  (format t "~&done. frames: ~D~%" *frames*)
  *frames*)
