;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; focus.lisp --- Cursor focus to surfaces
;;;
;;; MIT license.
;;;
;;; The core helper, UPDATE-POINTER-FOCUS, is what a compositor runs on every
;;; cursor motion: find the scene node under the cursor, resolve it to a
;;; wlr_surface, and give that surface the seat's pointer focus (enter + motion);
;;; clear focus when the cursor is over nothing.  RUN-FOCUS demonstrates it by
;;; hosting a client, then warping the cursor onto and off the window and
;;; checking the seat's focused surface follows.

(in-package #:lispwc)

(defvar *seat-f* nil)
(defvar *focus-cursor* nil)
(defvar *client-surface* nil)
(defvar *mappedp* nil)

(defun update-pointer-focus (lx ly time)
  "Give the surface under (LX,LY) the pointer focus, or clear focus if none.
Returns the focused wlr_surface pointer, or NIL."
  (cffi:with-foreign-objects ((nx :double) (ny :double))
    (let ((node (wlr-scene-node-at *scene* (float lx 1d0) (float ly 1d0) nx ny)))
      (if (or (cffi:null-pointer-p node)
              (/= (cffi:foreign-slot-value node '(:struct wlr-scene-node) 'type)
                  +scene-node-buffer+))
          (progn (wlr-seat-pointer-clear-focus *seat-f*) nil)
          (let ((ss (wlr-scene-surface-try-from-buffer
                     (wlr-scene-buffer-from-node node))))
            (if (cffi:null-pointer-p ss)
                (progn (wlr-seat-pointer-clear-focus *seat-f*) nil)
                (let ((surface (cffi:foreign-slot-value
                                ss '(:struct wlr-scene-surface) 'surface)))
                  (wlr-seat-pointer-notify-enter *seat-f* surface
                                                 (cffi:mem-ref nx :double)
                                                 (cffi:mem-ref ny :double))
                  (wlr-seat-pointer-notify-motion *seat-f* time
                                                  (cffi:mem-ref nx :double)
                                                  (cffi:mem-ref ny :double))
                  surface)))))))

(defun seat-focus ()
  (cffi:foreign-slot-value *seat-f* '(:struct wlr-seat) 'focused-surface))

(defun focus-on-new-output (listener data)
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
                #'focus-on-frame)
  (wlr-output-schedule-frame *output*))

(defun focus-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base)))
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
     (lambda (l d) (declare (ignore l d))
       (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
         (wlr-xdg-toplevel-set-size toplevel 0 0))))
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
     (lambda (l d) (declare (ignore l d))
       (wlr-scene-node-set-position tree 100 100)   ; window at (100,100)
       (setf *client-surface* surface *mappedp* t)
       (format t "~&client mapped at (100,100)~%") (finish-output)))))

(defun report-focus (label lx ly)
  (let* ((surf (update-pointer-focus lx ly *frames*))
         (seat (seat-focus))
         (match (and surf (cffi:pointer-eq surf seat))))
    (format t "~&~A cursor (~D,~D): node-surface=~:[none~;yes~]  seat-focus=~:[NULL~;set~]~@[  MATCH~]~%"
            label lx ly surf (not (cffi:null-pointer-p seat))
            (or match (and (null surf) (cffi:null-pointer-p seat))))
    (finish-output)))

(defun focus-on-frame (listener data)
  (declare (ignore listener data))
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  ;; once the client is up, run a scripted cursor sequence
  (when *mappedp*
    (case *frames*
      (8  (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 150d0 150d0)
          (report-focus "INSIDE " 150 150))     ; over the window
      (16 (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 5d0 5d0)
          (report-focus "OUTSIDE" 5 5))         ; over nothing
      (24 (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 200d0 200d0)
          (report-focus "INSIDE " 200 200)
          (let ((serial (wlr-seat-pointer-notify-button *seat-f* *frames* 272 1)))
            (format t "  sent BTN_LEFT press to focused surface (serial ~D)~%" serial))
          (finish-output))
      (30 (wl-display-terminate *display*))))
  (when (> *frames* 400) (wl-display-terminate *display*))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun run-focus (&key (client "weston-simple-shm") (verbosity 1))
  "Host CLIENT, then move the cursor onto and off its window, confirming the
seat's pointer focus follows the cursor."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *client-surface* nil *mappedp* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((proc nil))
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
           (setf *seat-f* (wlr-seat-create *display* "seat0"))
           (wlr-seat-set-capabilities *seat-f* +wl-seat-capability-pointer+)
           (setf *focus-cursor* (wlr-cursor-create))
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'focus-on-new-toplevel))
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'focus-on-new-output)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (let ((out (wlr-headless-add-output backend 1280 720)))
             ;; map the cursor's coordinate space onto the output
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
  (format t "~&done.~%"))
