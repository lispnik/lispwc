;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; events.lisp --- Input events via wlr_cursor + libinput
;;;
;;; MIT license.
;;;
;;; Uses the libinput backend (wlr_backend_autocreate) so real devices are
;;; enumerated, a wlr_cursor that pointer devices attach to, and per-device key
;;; listeners.  Pointer motion/button and keyboard key handlers are Lisp
;;; closures.  Verifiable remotely by injecting events through /dev/uinput --
;;; libinput picks up the synthetic device exactly like a physical one.

(in-package #:lispwc)

(defvar *cursor* nil)
(defvar *layout* nil)
(defvar *input-events* 0)

(defun ev-on-cursor-motion-absolute (listener data)
  (declare (ignore listener data))
  (incf *input-events*)
  (format t "~&pointer motion (absolute)~%") (finish-output))

(defun ev-on-cursor-motion (listener data)
  (declare (ignore listener))
  (let ((dx (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-x))
        (dy (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-y)))
    (wlr-cursor-move *cursor* (cffi:null-pointer) dx dy)
    (incf *input-events*)
    (format t "~&pointer motion d=(~,1F,~,1F) -> cursor (~,1F,~,1F)~%"
            dx dy
            (cffi:foreign-slot-value *cursor* '(:struct wlr-cursor) 'x)
            (cffi:foreign-slot-value *cursor* '(:struct wlr-cursor) 'y))
    (finish-output)))

(defun ev-on-cursor-button (listener data)
  (declare (ignore listener))
  (let ((btn (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'button))
        (st  (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'state)))
    (incf *input-events*)
    (format t "~&pointer button ~D ~A~%" btn (if (= st 1) "pressed" "released"))
    (finish-output)))

(defun ev-on-key (listener data)
  (declare (ignore listener))
  (let ((kc (cffi:foreign-slot-value data '(:struct wlr-keyboard-key-event) 'keycode))
        (st (cffi:foreign-slot-value data '(:struct wlr-keyboard-key-event) 'state)))
    (incf *input-events*)
    (format t "~&key keycode ~D ~A~%" kc (if (= st 1) "pressed" "released"))
    (finish-output)))

(defun ev-on-new-input (listener data)
  (declare (ignore listener))
  (let ((type (cffi:foreign-slot-value data '(:struct wlr-input-device) 'type)))
    (format t "~&new_input: type ~D (~A)~%"
            type (case type (0 "keyboard") (1 "pointer") (2 "touch") (t "other")))
    (finish-output)
    (case type
      (1 (wlr-cursor-attach-input-device *cursor* data)    ; pointer -> cursor
         (format t "  attached pointer to cursor~%") (finish-output))
      (0 (let ((kb (wlr-keyboard-from-input-device data)))  ; keyboard -> key listener
           (add-listener (cffi:foreign-slot-pointer kb '(:struct wlr-keyboard) 'key)
                         #'ev-on-key)
           (format t "  added key listener~%") (finish-output))))))

(defun run-input (&key (injector nil) (seconds 8) (verbosity 1))
  "Bring up the libinput backend and report pointer/keyboard events for SECONDS.
If INJECTOR (a path) is given, launch it to generate synthetic events via
uinput.  Returns the number of input events seen."
  (setf *input-events* 0)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((proc nil) (timer-cb nil))
    (unwind-protect
         (let* ((loop (wl-display-get-event-loop *display*))
                (backend (wlr-backend-autocreate loop (cffi:null-pointer))))
           (when (cffi:null-pointer-p backend) (error "backend autocreate failed"))
           (setf *cursor* (wlr-cursor-create)
                 *layout* (wlr-output-layout-create *display*))
           (wlr-cursor-attach-output-layout *cursor* *layout*)
           (add-listener (cffi:foreign-slot-pointer *cursor* '(:struct wlr-cursor) 'motion)
                         #'ev-on-cursor-motion)
           (add-listener (cffi:foreign-slot-pointer *cursor* '(:struct wlr-cursor) 'motion-absolute)
                         #'ev-on-cursor-motion-absolute)
           (add-listener (cffi:foreign-slot-pointer *cursor* '(:struct wlr-cursor) 'button)
                         #'ev-on-cursor-button)
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-input)
                         #'ev-on-new-input)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           ;; bound the run with a timer (no frame loop here)
           (setf timer-cb (make-foreign-callback
                           (lambda (d) (declare (ignore d)) (wl-display-terminate *display*) 0)
                           :int '(:pointer)))
           (let ((src (wl-event-loop-add-timer loop timer-cb (cffi:null-pointer))))
             (wl-event-source-timer-update src (* seconds 1000)))
           (when injector
             (format t "~&launching injector: ~A~%" injector) (finish-output)
             (setf proc (uiop:launch-program (list injector) :output :interactive :error-output :interactive)))
           (format t "~&listening for input for ~D s...~%" seconds) (finish-output)
           (wl-display-run *display*))
      (when proc (ignore-errors (uiop:terminate-process proc :urgent t)))
      (free-listeners)
      (wl-display-destroy *display*)))
  (format t "~&done. input events seen: ~D~%" *input-events*)
  *input-events*)
