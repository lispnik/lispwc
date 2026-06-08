;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; popup.lisp --- xdg-popup support (menus, tooltips, dropdowns)
;;;
;;; MIT license.
;;;
;;; A popup is a transient child surface that hangs off a parent (a toplevel or
;;; another popup) and is positioned by an xdg_positioner.  ON-NEW-POPUP puts it
;;; in the scene under its PARENT's scene tree, so the wlr_scene helper does the
;;; relative-positioning math; we find the parent's tree via a pointer we stash
;;; in the parent xdg_surface's `data`.  Wired into RUN-CONSOLE; verified by
;;; RUN-POPUP, which right-clicks weston-terminal to open its menu.

(in-package #:lispwc)

(defvar *popups* 0)
(defvar *clicked* nil)
(defvar *warp-frame* nil)
(defvar *popup-done-frame* nil)

(defun store-scene-tree (base tree)
  "Stash a scene tree on an xdg_surface so child popups can find it."
  (setf (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'data) tree))

(defun scene-tree-of (base)
  (let ((d (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'data)))
    (if (cffi:null-pointer-p d) nil d)))

(defun on-new-popup (listener data)
  "Place a new popup in the scene under its parent's tree."
  (declare (ignore listener))
  (let* ((popup  data)
         (base   (cffi:foreign-slot-value popup '(:struct wlr-xdg-popup) 'base))
         (parent (cffi:foreign-slot-value popup '(:struct wlr-xdg-popup) 'parent))
         (pxdg   (if (cffi:null-pointer-p parent)
                     (cffi:null-pointer)
                     (wlr-xdg-surface-try-from-wlr-surface parent)))
         (ptree  (and (not (cffi:null-pointer-p pxdg)) (scene-tree-of pxdg))))
    (let ((tree (wlr-scene-xdg-surface-create (or ptree *scene*) base)))
      (store-scene-tree base tree)        ; so nested popups hang off this one
      (incf *popups*)
      (when (null *popup-done-frame*) (setf *popup-done-frame* *frames*))
      (format t "~&new_popup: menu surface created (parent: ~:[scene root~;window~])~%"
              ptree)
      (finish-output))))

;;; --- headless verification: open weston-terminal's right-click menu ---

(defun popup-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base)))
    (store-scene-tree base tree)          ; popups will look this up by parent
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'commit)
     (lambda (l d) (declare (ignore l d))
       (when (plusp (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'initial-commit))
         (wlr-xdg-toplevel-set-size toplevel 0 0))))
    (add-listener
     (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'map)
     (lambda (l d) (declare (ignore l d))
       (wlr-scene-node-set-position tree 50 50)
       (setf *client-surface* surface *mappedp* t)
       (format t "~&terminal mapped at (50,50)~%") (finish-output)))))

(defun popup-on-frame (listener data)
  (declare (ignore listener data))
  (reap-listeners)
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  ;; move the pointer onto the terminal so it gets wl_pointer.enter
  (when (and *mappedp* (not *warped*))
    (wlr-cursor-warp *focus-cursor* (cffi:null-pointer) 150d0 150d0)
    (update-pointer-focus 150 150 *frames*)
    (setf *warped* t *warp-frame* *frames*)
    (format t "~&pointer entered the terminal at (150,150)~%") (finish-output))
  ;; a moment later, right-click to open the menu (an xdg-popup)
  (when (and *warped* (not *clicked*) (> *frames* (+ *warp-frame* 20)))
    (wlr-seat-pointer-notify-button *seat-f* *frames* 273 1)   ; BTN_RIGHT press
    (wlr-seat-pointer-notify-button *seat-f* *frames* 273 0)   ; release
    (setf *clicked* t)
    (format t "~&right-clicked the terminal (expecting a menu popup)~%") (finish-output))
  (cond ((and *popup-done-frame* (> *frames* (+ *popup-done-frame* 6)))
         (wl-display-terminate *display*))
        ((> *frames* 800)
         (format t "~&(no popup appeared)~%") (finish-output)
         (wl-display-terminate *display*)))
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))

(defun popup-on-new-output (listener data)
  (declare (ignore listener))
  (setf *output* data)
  (wlr-output-init-render *output* *allocator* *renderer*)
  (cffi:with-foreign-object (state '(:struct wlr-output-state))
    (wlr-output-state-init state)
    (wlr-output-state-set-enabled state t)
    (wlr-output-state-set-custom-mode state 1280 720 60000)
    (wlr-output-commit-state *output* state)
    (wlr-output-state-finish state))
  (let ((layout (wlr-output-layout-create *display*)))
    (wlr-output-layout-add-auto layout *output*)
    (wlr-cursor-attach-output-layout *focus-cursor* layout))
  (setf *scene-output* (wlr-scene-output-create *scene* *output*))
  (add-listener (cffi:foreign-slot-pointer *output* '(:struct wlr-output) 'frame)
                #'popup-on-frame)
  (wlr-output-schedule-frame *output*))

(defun run-popup (&key (client "weston-terminal") (verbosity 1))
  "Host CLIENT, right-click it, and confirm the menu it opens (an xdg-popup) is
created and placed under its parent window in the scene."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *client-surface* nil *mappedp* nil *warped* nil
        *popups* 0 *clicked* nil *warp-frame* nil *popup-done-frame* nil)
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
           (setf *focus-cursor* (wlr-cursor-create))
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'popup-on-new-toplevel)
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-popup)
                           #'on-new-popup))
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'popup-on-new-output)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (let ((out (wlr-headless-add-output backend 1280 720)))
             (wlr-output-create-global out *display*))
           (let ((socket (wl-display-add-socket-auto *display*)))
             (format t "~&socket ~A; launching ~A~%" socket client) (finish-output)
             (setf proc (uiop:launch-program
                         (list "/bin/sh" "-c"
                               (format nil "WAYLAND_DISPLAY=~A exec ~A" socket client))
                         :output :interactive :error-output :interactive)))
           (wl-display-run *display*))
      (when proc (ignore-errors (uiop:terminate-process proc :urgent t)))
      (free-listeners)                                    ; unlink while surfaces are alive
      (ignore-errors (wl-display-destroy-clients *display*))  ; then drop clients (popup grab!)
      (wl-display-destroy *display*)))
  (format t "~&done. popups created: ~D~%" *popups*))
