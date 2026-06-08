;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; console.lisp --- The whole thing on a real console (DRM + libinput)
;;;
;;; MIT license.
;;;
;;; RUN-CONSOLE is the interactive compositor wired together on the real
;;; backend: wlr_backend_autocreate picks DRM/KMS for the monitor and libinput
;;; for the mouse/keyboard, and the same closures verified headlessly elsewhere
;;; drive it -- pointer focus follows the cursor, a click raises and focuses the
;;; window under it (click-to-raise + keyboard focus), left-drag moves it and
;;; right-drag resizes it, and keys go to the focused window.
;;;
;;; Needs DRM master + a seat, so run from a Linux text console (a VT), as root
;;; or under seatd/logind, with a monitor connected.  See the README section
;;; "Running on a real console from scratch".

(in-package #:lispwc)

;; interactive grab state (the window currently being moved/resized)
(defvar *cgrab-mode* nil)               ; nil | :move | :resize
(defvar *cgrab-win* nil)
(defvar *cgrab-off-x* 0) (defvar *cgrab-off-y* 0)
(defvar *cgrab-cx* 0d0)  (defvar *cgrab-cy* 0d0)
(defvar *cgrab-sw* 0)    (defvar *cgrab-sh* 0)
(defvar *cursor-mgr* nil)               ; xcursor theme manager
(defvar *focused-win* nil)              ; window with the keyboard focus

(defun console-on-cursor-motion (listener data)
  (declare (ignore listener))
  (let ((dx (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-x))
        (dy (cffi:foreign-slot-value data '(:struct wlr-pointer-motion-event) 'delta-y)))
    (wlr-cursor-move *focus-cursor* (cffi:null-pointer) dx dy))
  (multiple-value-bind (cx cy) (cursor-xy)
    (case *cgrab-mode*
      (:move
       (let ((w *cgrab-win*))
         (setf (win-x w) (round (- cx *cgrab-off-x*)) (win-y w) (round (- cy *cgrab-off-y*)))
         (wlr-scene-node-set-position (win-tree w) (win-x w) (win-y w))))
      (:resize
       (let ((w *cgrab-win*))
         (setf (win-w w) (max 1 (round (+ *cgrab-sw* (- cx *cgrab-cx*))))
               (win-h w) (max 1 (round (+ *cgrab-sh* (- cy *cgrab-cy*)))))
         (wlr-xdg-toplevel-set-size (win-toplevel w) (win-w w) (win-h w))))
      (t (update-pointer-focus cx cy *frames*)))))

(defun console-on-cursor-button (listener data)
  (declare (ignore listener))
  (let ((btn   (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'button))
        (state (cffi:foreign-slot-value data '(:struct wlr-pointer-button-event) 'state)))
    (cond
      ((= state 1)                      ; press: raise + focus + begin a grab
       (multiple-value-bind (cx cy) (cursor-xy)
         (let ((w (top-window-at cx cy)))
           (when w
             (wlr-scene-node-raise-to-top (win-tree w))         ; click-to-raise
             (update-pointer-focus cx cy *frames*)              ; pointer focus
             (when (win-surface w) (focus-keyboard (win-surface w)))  ; keyboard focus
             (setf *focused-win* w)
             (if (= btn 273)
                 (setf *cgrab-mode* :resize *cgrab-win* w
                       *cgrab-cx* cx *cgrab-cy* cy *cgrab-sw* (win-w w) *cgrab-sh* (win-h w))
                 (setf *cgrab-mode* :move *cgrab-win* w
                       *cgrab-off-x* (- cx (win-x w)) *cgrab-off-y* (- cy (win-y w))))))))
      (t (setf *cgrab-mode* nil *cgrab-win* nil)))               ; release: end grab
    (wlr-seat-pointer-notify-button *seat-f* *frames* btn state)))

(defun console-on-request-set-cursor (listener data)
  "A client asked to set its own pointer image; honor it if that client has
pointer focus (so a background client can't hijack the cursor)."
  (declare (ignore listener))
  (let ((sc  (cffi:foreign-slot-value
              data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-seat-client))
        (foc (cffi:foreign-slot-value *seat-f* '(:struct wlr-seat) 'focused-client)))
    (when (cffi:pointer-eq sc foc)
      (wlr-cursor-set-surface
       *focus-cursor*
       (cffi:foreign-slot-value
        data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-surface)
       (cffi:foreign-slot-value
        data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-hotspot-x)
       (cffi:foreign-slot-value
        data '(:struct wlr-seat-pointer-request-set-cursor-event) 'rsc-hotspot-y)))))

(defun focus-window (w)
  "Raise W, give it the keyboard focus, and record it as focused."
  (when w
    (wlr-scene-node-raise-to-top (win-tree w))
    (when (win-surface w) (focus-keyboard (win-surface w)))
    (setf *focused-win* w)))

(defun cycle-focus ()
  "Alt+Tab: focus (and raise) the next window in the list."
  (when (>= (length *wins*) 2)
    (let* ((pos  (position *focused-win* *wins*))
           (next (nth (mod (1+ (or pos -1)) (length *wins*)) *wins*)))
      (focus-window next)
      (format t "~&Alt+Tab: focus window ~D~%" (win-label next)) (finish-output))))

(defun close-focused ()
  "Alt+F4: ask the focused window's client to close."
  (let ((w *focused-win*))
    (when (and w (win-toplevel w))
      (wlr-xdg-toplevel-send-close (win-toplevel w))
      (format t "~&Alt+F4: close window ~D~%" (win-label w)) (finish-output))))

(defun console-key (kbd data)
  "Intercept compositor keybindings (Alt+Tab / Alt+F4 / Alt+Esc); otherwise
forward the key to the focused client."
  (let ((kc (cffi:foreign-slot-value data '(:struct wlr-keyboard-key-event) 'keycode))
        (st (cffi:foreign-slot-value data '(:struct wlr-keyboard-key-event) 'state)))
    (when (= st 1)                                  ; on press, check for a binding
      (let ((mods (wlr-keyboard-get-modifiers kbd))
            (sym  (keyboard-keysym kbd kc)))
        (when (logtest mods +mod-alt+)
          (cond
            ((= sym +key-tab+)    (cycle-focus)   (return-from console-key))
            ((= sym +key-f4+)     (close-focused) (return-from console-key))
            ((= sym +key-escape+) (format t "~&Alt+Esc: quit~%") (finish-output)
                                  (wl-display-terminate *display*)
                                  (return-from console-key))))))
    (wlr-seat-keyboard-notify-key *seat-f* *frames* kc st)))

(defun console-on-new-input (listener data)
  (declare (ignore listener))
  (let ((type (cffi:foreign-slot-value data '(:struct wlr-input-device) 'type)))
    (case type
      (1 (wlr-cursor-attach-input-device *focus-cursor* data)
         (format t "~&new_input: pointer attached~%"))
      (0 (let ((kbd (wlr-keyboard-from-input-device data)))
           (keyboard-set-default-keymap kbd)        ; so modifiers track + keysyms resolve
           (wlr-seat-set-keyboard *seat-f* kbd)
           (add-listener (cffi:foreign-slot-pointer kbd '(:struct wlr-keyboard) 'key)
                         (lambda (l d) (declare (ignore l)) (console-key kbd d))))
         (format t "~&new_input: keyboard attached (keymap set)~%")))
    (finish-output)))

(defun console-on-new-toplevel (listener data)
  (declare (ignore listener))
  (let* ((toplevel data)
         (base    (cffi:foreign-slot-value toplevel '(:struct wlr-xdg-toplevel) 'base))
         (surface (cffi:foreign-slot-value base '(:struct wlr-xdg-surface) 'surface))
         (tree    (wlr-scene-xdg-surface-create *scene* base))
         (idx     *next-idx*)
         (px      (+ 40 (* 60 idx)))
         (py      (+ 40 (* 60 idx)))
         (w       (make-win :label (1+ idx) :tree tree :toplevel toplevel :x px :y py)))
    (incf *next-idx*)
    (store-scene-tree base tree)          ; so this window's popups (menus) find it
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
              (setf (win-surface w) surface
                    (win-w w) (cffi:foreign-slot-value surface '(:struct wlr-surface) 'cur-width)
                    (win-h w) (cffi:foreign-slot-value surface '(:struct wlr-surface) 'cur-height))
              (wlr-scene-node-set-position tree px py)
              (pushnew w *wins*)
              (focus-window w)                                  ; raise + focus the newest window
              (format t "~&window ~D mapped at (~D,~D)~%" (win-label w) px py)
              (finish-output)))
           (add-listener
            (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'unmap)
            (lambda (l d) (declare (ignore l d))
              (setf *wins* (remove w *wins*))                   ; hidden; scene node auto-hides
              (when (eq *focused-win* w) (setf *focused-win* nil))
              (when (eq *cgrab-win* w) (setf *cgrab-mode* nil *cgrab-win* nil))))
           (add-listener
            (cffi:foreign-slot-pointer surface '(:struct wlr-surface) 'destroy)
            (lambda (l d) (declare (ignore l d))
              (when (eq *cgrab-win* w) (setf *cgrab-mode* nil *cgrab-win* nil))
              (when (eq *focused-win* w) (setf *focused-win* nil))
              (forget-window w)                                 ; unlink listeners now, free later
              (format t "~&window ~D destroyed~%" (win-label w)) (finish-output)))))))

(defun console-on-frame (listener data)
  (declare (ignore listener data))
  (reap-listeners)                          ; free closures of windows closed last frame
  (unless (cffi:null-pointer-p *scene-output*)
    (wlr-scene-output-commit *scene-output* (cffi:null-pointer))
    (cffi:with-foreign-object (ts '(:struct timespec))
      (clock-gettime +clock-monotonic+ ts)
      (wlr-scene-output-send-frame-done *scene-output* ts)))
  (incf *frames*)
  (when (and *output* (not (cffi:null-pointer-p *output*)))
    (wlr-output-schedule-frame *output*)))   ; run forever (until killed)

(defun console-on-new-output (listener data)
  (declare (ignore listener))
  (setf *output* data)
  (wlr-output-init-render *output* *allocator* *renderer*)
  (cffi:with-foreign-object (state '(:struct wlr-output-state))
    (wlr-output-state-init state)
    (wlr-output-state-set-enabled state t)
    (let ((mode (wlr-output-preferred-mode *output*)))    ; real monitors have modes
      (if (cffi:null-pointer-p mode)
          (wlr-output-state-set-custom-mode state 1280 720 0)
          (wlr-output-state-set-mode state mode)))
    (wlr-output-commit-state *output* state)
    (wlr-output-state-finish state))
  (wlr-output-create-global *output* *display*)   ; advertise wl_output (layer-shell needs it)
  (let ((layout (wlr-output-layout-create *display*)))
    (wlr-output-layout-add-auto layout *output*)
    (wlr-cursor-attach-output-layout *focus-cursor* layout))
  ;; load the theme for this output's scale and show the default pointer
  (let ((ok (wlr-xcursor-manager-load *cursor-mgr* 1.0)))
    (wlr-cursor-set-xcursor *focus-cursor* *cursor-mgr* "default")
    (format t "~&cursor theme loaded=~A~%" ok))
  (setf *scene-output* (wlr-scene-output-create *scene* *output*))
  ;; a dim background so the desktop is visible behind the windows
  (cffi:with-foreign-object (color :float 4)
    (setf (cffi:mem-aref color :float 0) 0.10 (cffi:mem-aref color :float 1) 0.12
          (cffi:mem-aref color :float 2) 0.16 (cffi:mem-aref color :float 3) 1.0)
    (let ((bg (wlr-scene-rect-create *scene* 8192 8192 color)))
      (wlr-scene-node-set-position bg 0 0)))
  (add-listener (cffi:foreign-slot-pointer *output* '(:struct wlr-output) 'frame)
                #'console-on-frame)
  (wlr-output-schedule-frame *output*)
  (format t "~&new_output: display configured~%") (finish-output))

(defun run-console (&key (clients '("weston-simple-shm")) (verbosity 2))
  "Bring up the interactive compositor on the real backend (DRM + libinput) and
launch CLIENTS.  Runs until you kill it (Ctrl-C / switch VT).  Needs DRM master
+ a seat -- run from a text console; see the README."
  (setf *frames* 0 *output* nil *scene-output* (cffi:null-pointer)
        *wins* nil *next-idx* 0 *cgrab-mode* nil *cgrab-win* nil *cursor-mgr* nil
        *focused-win* nil)
  (wlr-log-init verbosity (cffi:null-pointer))
  (setf *display* (wl-display-create))
  (let ((procs nil))
    (unwind-protect
         (let* ((loop    (wl-display-get-event-loop *display*))
                (backend (wlr-backend-autocreate loop (cffi:null-pointer))))
           (when (cffi:null-pointer-p backend)
             (error "wlr_backend_autocreate failed (no DRM master / session?)"))
           (setf *renderer*  (wlr-renderer-autocreate backend)
                 *allocator* (wlr-allocator-autocreate backend *renderer*)
                 *scene*     (wlr-scene-create))
           (wlr-renderer-init-wl-display *renderer* *display*)
           (wlr-compositor-create *display* 6 *renderer*)
           (wlr-subcompositor-create *display*)
           (wlr-data-device-manager-create *display*)
           (setf *seat-f* (wlr-seat-create *display* "seat0"))
           (wlr-seat-set-capabilities
            *seat-f* (logior +wl-seat-capability-pointer+ +wl-seat-capability-keyboard+))
           (add-listener (cffi:foreign-slot-pointer *seat-f* '(:struct wlr-seat) 'request-set-cursor)
                         #'console-on-request-set-cursor)
           (setf *focus-cursor* (wlr-cursor-create))
           ;; a visible pointer: load a cursor theme and show the default arrow
           (setf *cursor-mgr* (wlr-xcursor-manager-create (cffi:null-pointer) 24))
           (let ((ok (wlr-xcursor-manager-load *cursor-mgr* 1.0)))
             (wlr-cursor-set-xcursor *focus-cursor* *cursor-mgr* "default")
             (format t "~&cursor theme loaded=~A~%" ok) (finish-output))
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'motion)
                         #'console-on-cursor-motion)
           (add-listener (cffi:foreign-slot-pointer *focus-cursor* '(:struct wlr-cursor) 'button)
                         #'console-on-cursor-button)
           (let ((xdg (wlr-xdg-shell-create *display* 3)))
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-toplevel)
                           #'console-on-new-toplevel)
             (add-listener (cffi:foreign-slot-pointer xdg '(:struct wlr-xdg-shell) 'new-popup)
                           #'on-new-popup))                ; menus, dropdowns
           ;; layer-shell: panels and backgrounds
           (let ((layer-shell (wlr-layer-shell-v1-create *display* 4)))
             (add-listener (cffi:foreign-slot-pointer layer-shell '(:struct wlr-layer-shell-v1) 'new-surface)
                           #'layer-on-new-surface))
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-output)
                         #'console-on-new-output)
           (add-listener (cffi:foreign-slot-pointer backend '(:struct wlr-backend) 'new-input)
                         #'console-on-new-input)
           (unless (wlr-backend-start backend) (error "backend start failed"))
           (let ((socket (wl-display-add-socket-auto *display*)))
             (format t "~&compositor socket: ~A~%" socket) (finish-output)
             (dolist (c clients)
               (push (uiop:launch-program
                      (list "/bin/sh" "-c"
                            (format nil "WAYLAND_DISPLAY=~A exec ~A" socket c))
                      :output :interactive :error-output :interactive)
                     procs)))
           (wl-display-run *display*))
      (dolist (p procs) (ignore-errors (uiop:terminate-process p :urgent t)))
      (free-listeners)                                    ; unlink while surfaces are alive
      (ignore-errors (wl-display-destroy-clients *display*))  ; then drop clients (popup grabs)
      (wl-display-destroy *display*)))
  (format t "~&done.~%"))
