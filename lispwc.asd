;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; lispwc.asd --- A minimal Wayland compositor in Common Lisp (wlroots)
;;;
;;; Every wl_listener callback is a libffi closure (cffi-callback-closures).
;;; Linux + wlroots 0.19.

(in-package :asdf)

(defsystem "lispwc"
  :description "Minimal wlroots Wayland compositor; callbacks are Lisp closures."
  :author "Matthew Kennedy"
  :license "MIT"
  :defsystem-depends-on ("cffi-grovel")
  :depends-on ("cffi" "cffi-callback-closures")
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:cffi-grovel-file "grovel")
                             (:file "wayland")
                             (:file "wlroots")
                             (:file "main")
                             (:file "xdg")
                             (:file "input")
                             (:file "drm")
                             (:file "events")
                             (:file "focus")
                             (:file "live-focus")
                             (:file "move-resize")
                             (:file "stack")
                             (:file "layer")
                             (:file "console")
                             (:file "cursor")
                             (:file "teardown")
                             (:file "cli")))))
