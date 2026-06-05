;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; main.lisp --- Milestone 1: headless bring-up
;;;
;;; MIT license.
;;;
;;; Brings up a headless wlroots compositor and renders a solid-color frame on a
;;; loop, terminating after N frames.  The new_output and frame handlers are
;;; Lisp closures over the run's state -- the whole point of the exercise.

(in-package #:lispwc)

(defvar *display* nil)
(defvar *scene* nil)
(defvar *renderer* nil)
(defvar *allocator* nil)
(defvar *output* nil)
(defvar *scene-output* nil)
(defvar *frames* 0)
(defvar *max-frames* 30)

(defun on-frame (listener data)
  "wlr_output.events.frame: render the scene and present a frame."
  (declare (ignore listener data))
  (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
  (cffi:with-foreign-object (ts '(:struct timespec))
    (clock-gettime +clock-monotonic+ ts)
    (wlr-scene-output-send-frame-done *scene-output* ts))
  (incf *frames*)
  (if (>= *frames* *max-frames*)
      (progn (format t "~&committed ~D frames; terminating~%" *frames*)
             (finish-output)
             (wl-display-terminate *display*))
      (wlr-output-schedule-frame *output*)))   ; keep the loop going

(defun on-new-output (listener data)
  "wlr_backend.events.new_output: configure the output, add a colored rect to
the scene, and start listening for frames."
  (declare (ignore listener))
  (setf *output* data)
  (wlr-output-init-render *output* *allocator* *renderer*)
  (cffi:with-foreign-object (state '(:struct wlr-output-state))
    (wlr-output-state-init state)
    (wlr-output-state-set-enabled state t)
    (wlr-output-state-set-custom-mode state 1280 720 60000) ; 1280x720 @ 60Hz (mHz)
    (let ((ok (wlr-output-commit-state *output* state)))
      (wlr-output-state-finish state)
      (format t "~&new_output: configured 1280x720, commit=~A~%" ok)
      (finish-output)))
  (setf *scene-output* (wlr-scene-output-create *scene* *output*))
  ;; a solid color rect filling the output (scene ptr == &scene->tree, offset 0)
  (cffi:with-foreign-object (color :float 4)
    (setf (cffi:mem-aref color :float 0) 0.10
          (cffi:mem-aref color :float 1) 0.20
          (cffi:mem-aref color :float 2) 0.45
          (cffi:mem-aref color :float 3) 1.0)
    (wlr-scene-rect-create *scene* 1280 720 color))
  (add-listener (cffi:foreign-slot-pointer *output* '(:struct wlr-output) 'frame)
                #'on-frame)
  (wlr-output-schedule-frame *output*))

(defun %zero (ptr nbytes)
  (dotimes (i nbytes) (setf (cffi:mem-aref ptr :uint8 i) 0)))

(defun render-color-test (&key (width 64) (height 64) (verbosity 1)
                               (rgb '(0.10 0.20 0.45)))
  "M1.5: render a solid color into a CPU buffer with a wlr_render_pass, then
read pixel (0,0) back.  Returns (values r g b) as 0-255.  Use
WLR_RENDERER=pixman so the buffer is CPU-mappable."
  (destructuring-bind (cr cg cb) rgb
    (wlr-log-init verbosity (cffi:null-pointer))
    (let* ((display (wl-display-create))
           (loop (wl-display-get-event-loop display))
           (backend (wlr-headless-backend-create loop))
           (renderer (wlr-renderer-autocreate backend))
           (allocator (wlr-allocator-autocreate backend renderer)))
      (unwind-protect
           (cffi:with-foreign-object (fmt '(:struct wlr-drm-format))
             (%zero fmt (cffi:foreign-type-size '(:struct wlr-drm-format)))
             (setf (cffi:foreign-slot-value fmt '(:struct wlr-drm-format) 'format)
                   +drm-format-xrgb8888+)               ; len=0, modifiers=NULL => implicit
             (let ((buf (wlr-allocator-create-buffer allocator width height fmt)))
               (when (cffi:null-pointer-p buf) (error "create_buffer failed"))
               (unwind-protect
                    (progn
                      (let ((pass (wlr-renderer-begin-buffer-pass renderer buf
                                                                  (cffi:null-pointer))))
                        (when (cffi:null-pointer-p pass) (error "begin_buffer_pass failed"))
                        (cffi:with-foreign-object (o '(:struct wlr-render-rect-options))
                          (%zero o (cffi:foreign-type-size '(:struct wlr-render-rect-options)))
                          (macrolet ((s (slot v) `(setf (cffi:foreign-slot-value
                                                         o '(:struct wlr-render-rect-options)
                                                         ',slot) ,v)))
                            (s box-x 0) (s box-y 0) (s box-width width) (s box-height height)
                            (s r (float cr 1f0)) (s g (float cg 1f0))
                            (s b (float cb 1f0)) (s a 1f0))
                          (wlr-render-pass-add-rect pass o))
                        (unless (wlr-render-pass-submit pass) (error "submit failed")))
                      (cffi:with-foreign-objects ((data :pointer) (pf :uint32) (stride :unsigned-long))
                        (unless (wlr-buffer-begin-data-ptr-access
                                 buf +wlr-buffer-data-ptr-access-read+ data pf stride)
                          (error "data_ptr_access failed (use WLR_RENDERER=pixman)"))
                        (let* ((px (cffi:mem-ref data :pointer))
                               ;; XRGB8888 little-endian: B,G,R,X
                               (b8 (cffi:mem-aref px :uint8 0))
                               (g8 (cffi:mem-aref px :uint8 1))
                               (r8 (cffi:mem-aref px :uint8 2)))
                          (wlr-buffer-end-data-ptr-access buf)
                          (format t "~&read-back pixel (0,0): R=~D G=~D B=~D  (asked ~D ~D ~D)~%"
                                  r8 g8 b8 (round (* cr 255)) (round (* cg 255)) (round (* cb 255)))
                          (finish-output)
                          (values r8 g8 b8))))
                 (wlr-buffer-drop buf))))
        (wl-display-destroy display)))))

(defun run-headless (&key (frames 30) (verbosity 2))
  "Run a headless compositor: render FRAMES solid-color frames, then exit.
Returns the number of frames committed."
  (setf *frames* 0 *max-frames* frames *output* nil *scene-output* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (unwind-protect
       (let* ((loop (wl-display-get-event-loop *display*))
              (backend (wlr-headless-backend-create loop)))
         (when (cffi:null-pointer-p backend) (error "headless backend create failed"))
         (setf *renderer*  (wlr-renderer-autocreate backend)
               *allocator* (wlr-allocator-autocreate backend *renderer*)
               *scene*     (wlr-scene-create))
         (when (cffi:null-pointer-p *renderer*)  (error "renderer autocreate failed"))
         (when (cffi:null-pointer-p *allocator*) (error "allocator autocreate failed"))
         (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                       #'on-new-output)
         (unless (wlr-backend-start backend) (error "backend start failed"))
         (wlr-headless-add-output backend 1280 720)   ; -> fires new_output
         (format t "~&running event loop (target ~D frames)...~%" frames)
         (finish-output)
         (wl-display-run *display*))
    (free-listeners)
    (wl-display-destroy *display*))
  (format t "~&done. frames committed: ~D~%" *frames*)
  *frames*)
