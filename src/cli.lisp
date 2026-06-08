;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; cli.lisp --- Command-line entry point for a saved executable image
;;;
;;; MIT license.
;;;
;;; MAIN is the toplevel of the image built by build.sh
;;; (sb-ext:save-lisp-and-die ... :toplevel #'lispwc:main).  It dispatches the
;;; first argument to one of the RUN-* demos:
;;;
;;;   ./lispwc console weston-simple-shm
;;;   ./lispwc headless --frames 60
;;;   ./lispwc move-resize --injector /tmp/inject-drag

(in-package #:lispwc)

(defun %opt (args name &optional default)
  "Value following --NAME in ARGS, or DEFAULT."
  (let ((p (position name args :test #'string=)))
    (if (and p (< (1+ p) (length args))) (nth (1+ p) args) default)))

(defun %int (s) (if s (parse-integer s) nil))

(defun %positional (args)
  "ARGS with --opt VALUE pairs removed (what's left are bare arguments)."
  (loop with out = '() with i = 0
        while (< i (length args))
        for a = (nth i args)
        do (if (and (>= (length a) 2) (string= "--" (subseq a 0 2)))
               (incf i 2)                       ; skip --opt and its value
               (progn (push a out) (incf i)))
        finally (return (nreverse out))))

(defun print-usage ()
  (format t "~
usage: lispwc <command> [options]

headless backed demos (no root, run over SSH):
  headless [--frames N]        solid-color frame loop
  color-test                   render a rect, read the pixel back
  client [--client CMD]        host one xdg-shell client
  multi [--clients N]          several tiled windows
  focus [--client CMD]         scripted cursor + keyboard focus
  stack [--client CMD]         click-to-raise / window stacking
  cursor [--client CMD]        honor a client's wl_pointer.set_cursor
  layer [--client CMD]         layer-shell panel/background (swaybg)
  popup [--client CMD]         xdg-popup menus (right-clicks weston-terminal)
  teardown [--client CMD]      open+close a window, verify closures freed

device-backed demos (need root: libinput/DRM session):
  input [--injector PATH]      libinput events via /dev/uinput
  live-focus [--injector PATH] real input driving focus
  move-resize [--injector PATH] real button-drags move/resize a window
  keys [--injector PATH]       compositor keybindings (Alt+Tab/F4/Esc)
  drm [--frames N]             fill the real monitor blue
  console [CLIENT...]          the whole interactive compositor on a real display

In console/keys, the compositor keybindings are:
  Alt+Tab  cycle + raise the next window     Alt+F4  close the focused window
  Alt+Esc  quit the compositor
~%"))

(defun main ()
  "Toplevel for the saved executable; dispatch argv to a RUN-* demo."
  (let* ((args (uiop:command-line-arguments))
         (cmd  (first args))
         (opts (rest args)))
    (handler-case
        (cond
          ((or (null cmd) (member cmd '("help" "-h" "--help") :test #'string=))
           (print-usage))
          ((string= cmd "headless")    (run-headless :frames (or (%int (%opt opts "--frames")) 30)))
          ((string= cmd "color-test")  (render-color-test))
          ((string= cmd "client")      (run-with-client :client (%opt opts "--client" "weston-simple-shm")))
          ((string= cmd "multi")       (run-multi :clients (or (%int (%opt opts "--clients")) 2)))
          ((string= cmd "focus")       (run-focus :client (%opt opts "--client" "weston-simple-shm")))
          ((string= cmd "stack")       (run-stack :client (%opt opts "--client" "weston-simple-shm")))
          ((string= cmd "cursor")      (run-cursor :client (%opt opts "--client" "weston-flower")))
          ((string= cmd "layer")       (run-layer :client (%opt opts "--client" "swaybg -c 224488")))
          ((string= cmd "popup")       (run-popup :client (%opt opts "--client" "weston-terminal")))
          ((string= cmd "teardown")    (run-teardown :client (%opt opts "--client" "weston-simple-shm")))
          ((string= cmd "input")       (run-input :injector (%opt opts "--injector" "/tmp/inject")))
          ((string= cmd "live-focus")  (run-live-focus :injector (%opt opts "--injector" "/tmp/inject")))
          ((string= cmd "move-resize") (run-move-resize :injector (%opt opts "--injector" "/tmp/inject-drag")))
          ((string= cmd "keys")        (run-keys :injector (%opt opts "--injector" "/tmp/inject-keys")))
          ((string= cmd "drm")         (run-drm :frames (or (%int (%opt opts "--frames")) 180)))
          ((string= cmd "console")     (run-console :clients (or (%positional opts) '("weston-simple-shm"))))
          (t (format *error-output* "lispwc: unknown command ~S~%~%" cmd)
             (print-usage)
             (sb-ext:exit :code 2)))
      (error (e)
        (format *error-output* "lispwc: ~A~%" e)
        (sb-ext:exit :code 1)))
    (sb-ext:exit :code 0)))
