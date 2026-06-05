;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; lispwc.asd --- A minimal Wayland compositor in Common Lisp (wlroots)
;;;
;;; Milestone 1: headless bring-up.  wl_display + headless backend + one output
;;; + a wlr_scene solid-color frame loop, with every wl_listener wired as a
;;; libffi closure (cffi-callback-closures).  Linux + wlroots 0.19.

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
                             (:file "xdg")))))
