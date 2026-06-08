;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; teardown.lisp --- Window destroy/unmap teardown, and a test for it
;;;
;;; MIT license.
;;;
;;; The other demos only ever add listeners; this exercises the *free* side of
;;; the cffi-callback-closures lifecycle.  A window's surface gets unmap and
;;; destroy listeners (in addition to commit/map); on destroy we FORGET-WINDOW
;;; -- unlink its listeners while the surface's signals are still valid -- and
;;; the frame loop's REAP-LISTENERS frees the libffi trampolines afterwards
;;; (freeing one inside its own notify would be a use-after-free).
;;;
;;; RUN-TEARDOWN proves it headlessly: open a window, kill the client, and check
;;; the window is dropped, the listener count returns to its baseline, and the
;;; window's closures are no longer live.

(in-package #:lispwc)

(defvar *td-base* 0)        ; listener count before the window's listeners
(defvar *td-cbs* nil)       ; the window's foreign-callbacks, to check liveness
(defvar *td-mapped* nil)
(defvar *td-killed* nil)
(defvar *td-destroyed* nil)
(defvar *td-destroy-frame* nil)
(defvar *td-client* nil)

(defun td-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base))
         (w       (make-win :label 1 :tree tree :toplevel toplevel)))
    (setf *td-base* (length *listeners*))           ; baseline before this window
    (setf (win-listeners w)
          (list
           (add-listener
            (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
            (lambda (l d) (declare (ignore l d))
              (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
                (wlr-xdg-toplevel-set-size toplevel 0 0))))
           (add-listener
            (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
            (lambda (l d) (declare (ignore l d))
              (wlr-scene-node-set-position tree 100 100)
              (setf (win-surface w) surface)
              (pushnew w *wins*)
              (setf *td-mapped* t)
              (format t "~&window mapped: ~D live window(s), listeners ~D (was ~D), ~D window closures live~%"
                      (length *wins*) (length *listeners*) *td-base*
                      (count-if #'foreign-callback-live-p *td-cbs*))
              (finish-output)))
           (add-listener
            (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'unmap)
            (lambda (l d) (declare (ignore l d))
              (setf *wins* (remove w *wins*))
              (format t "~&surface unmapped: ~D live window(s)~%" (length *wins*)) (finish-output)))
           (add-listener
            (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'destroy)
            (lambda (l d) (declare (ignore l d))
              (forget-window w)                     ; unlink now; trampolines freed by reap
              (setf *td-destroyed* t *td-destroy-frame* *frames*)
              (format t "~&surface destroyed: listeners unlinked (now ~D)~%" (length *listeners*))
              (finish-output)))))
    (setf *td-cbs* (mapcar #'listener-callback (win-listeners w)))))

(defun td-on-frame (listener data)
  (declare (ignore listener data))
  (reap-listeners)                                  ; free trampolines of any closed window
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  ;; once the window is up, close the client to trigger unmap + destroy
  (when (and *td-mapped* (not *td-killed*) *td-client*)
    (format t "~&closing the client...~%") (finish-output)
    (ignore-errors (uiop:terminate-process *td-client*))
    (setf *td-killed* t))
  ;; a frame after destroy (so reap has run), check everything was cleaned up
  (when (and *td-destroyed* (> *frames* (1+ *td-destroy-frame*)))
    (let ((wins-empty   (null *wins*))
          (back-to-base (= (length *listeners*) *td-base*))
          (closures-gone (notany #'foreign-callback-live-p *td-cbs*)))
      (format t "~&teardown check:~%")
      (format t "  window dropped from registry ... ~:[FAIL~;ok~]~%" wins-empty)
      (format t "  listeners back to baseline ~D ... ~:[FAIL (~D)~;ok~]~%"
              *td-base* back-to-base (length *listeners*))
      (format t "  window closures freed (0 live) ... ~:[FAIL (~D live)~;ok~]~%"
              closures-gone (count-if #'foreign-callback-live-p *td-cbs*))
      (format t "~&RESULT: ~:[FAILED~;PASSED~]~%"
              (and wins-empty back-to-base closures-gone))
      (finish-output))
    (wl-display-terminate *display*))
  (when (> *frames* 400)
    (format t "~&(timed out before destroy)~%") (finish-output)
    (wl-display-terminate *display*))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun td-on-new-output (listener data)
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
                #'td-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-teardown (&key (client "weston-simple-shm") (verbosity 1))
  "Open a window, close the client, and confirm the window's listeners are
unlinked + freed and it is dropped from the registry (the free side of the
closure lifecycle)."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *wins* nil *next-idx* 0
        *td-base* 0 *td-cbs* nil *td-mapped* nil *td-killed* nil
        *td-destroyed* nil *td-destroy-frame* nil *td-client* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
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
         (let ((xdg (wlr-xdg-shell-create *display* 3)))
           (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                         #'td-on-new-toplevel))
         (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                       #'td-on-new-output)
         (unless (wlr-backend-start backend) (error "backend start failed"))
         (wlr-headless-add-output backend 1280 720)
         (let ((socket (wl-display-add-socket-auto *display*)))
           (format t "~&socket ~A; launching ~A~%" socket client) (finish-output)
           (setf *td-client* (uiop:launch-program
                              (list "/bin/sh" "-c"
                                    (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                              :output :interactive :error-output :interactive)))
         (wl-display-run *display*))
    (when *td-client* (ignore-errors (uiop:terminate-process *td-client* :urgent t)))
    (free-listeners)
    (wl-display-destroy *display*))
  (format t "~&done.~%"))
