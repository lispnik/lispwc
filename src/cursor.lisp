;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; cursor.lisp --- Honor client cursor requests (wl_pointer.set_cursor)
;;;
;;; MIT license.
;;;
;;; When the pointer enters a client's window the client may set its own cursor
;;; image (wl_pointer.set_cursor), which wlroots surfaces as the seat's
;;; request_set_cursor signal.  CONSOLE-ON-REQUEST-SET-CURSOR (in console.lisp)
;;; honors it.  RUN-CURSOR verifies it headlessly: host a toytoolkit client that
;;; sets a cursor (weston-flower), give it pointer focus, and confirm the
;;; request fires and is applied.

(in-package #:lispwc)

(defvar *cursor-reqs* 0)
(defvar *cursor-done-frame* nil)

(defun cursor-verify-on-request (listener data)
  (declare (ignore listener))
  (let ((sc   (cffi:foreign-slot-value
               data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-seat-client))
        (foc  (cffi:foreign-slot-value *seat-f* '(:struct wlr-seat) 'focused-client))
        (surf (cffi:foreign-slot-value
               data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-surface))
        (hx   (cffi:foreign-slot-value
               data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-hotspot-x))
        (hy   (cffi:foreign-slot-value
               data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-hotspot-y)))
    (incf *cursor-reqs*)
    (format t "~&client requested cursor: surface=~:[NULL (hide)~;set~] hotspot=(~D,~D) from-focused-client=~A~%"
            (not (cffi:null-pointer-p surf)) hx hy (cffi:pointer-eq sc foc))
    (when (cffi:pointer-eq sc foc)
      (wlr-cursor-set-surface *focus-cursor* surf hx hy)
      (format t "  -> applied via wlr_cursor_set_surface~%"))
    (when (null *cursor-done-frame*) (setf *cursor-done-frame* *frames*))
    (finish-output)))

(defun cursor-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  ;; once the client is up, move the pointer onto it -> it gets wl_pointer.enter
  ;; and (being a toytoolkit client) responds by setting its own cursor
  (when (and *mappedp* (not *warped*))
    (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 150d0 150d0)
    (setf *warped* t)
    (update-pointer-focus 150 150 *frames*)
    (format t "~&pointer entered the window at (150,150); waiting for the client to set its cursor~%")
    (finish-output))
  (cond ((and *cursor-done-frame* (> *frames* (+ *cursor-done-frame* 4)))
         (wl-display-terminate *display*))
        ((> *frames* 400)
         (format t "~&(no cursor request arrived)~%")
         (wl-display-terminate *display*)))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun cursor-on-new-output (listener data)
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
                #'cursor-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-cursor (&key (client "weston-flower") (verbosity 1))
  "Host a client that sets its own cursor, give it pointer focus, and confirm
the seat's request_set_cursor signal fires (and is applied)."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *client-surface* nil *mappedp* nil *warped* nil
        *cursor-reqs* 0 *cursor-done-frame* nil)
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
           (setf *seat-f* (wlr-seat-create *display* "seat0"))
           (wlr-seat-set-capabilities *seat-f* +wl-seat-capability-pointer+)
           (add-listener (cffi:foreign-slot-pointer *seat-f* '(:struct wlr-seat) 'request-set-cursor)
                         #'cursor-verify-on-request)
           (setf *focus-cursor* (wlr-cursor-create))
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'focus-on-new-toplevel))     ; reuse: places at (100,100)
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'cursor-on-new-output)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (let ((out (wlr-headless-add-output backend 1280 720)))
             (let ((layout (wlr-output-layout-create *display*)))
               (wlr-output-layout-add-auto layout out)
               (wlr-cursor-attach-output-layout *focus-cursor* layout)))
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
  (format t "~&done. cursor requests honored: ~D~%" *cursor-reqs*))
