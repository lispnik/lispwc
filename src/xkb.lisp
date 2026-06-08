;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; xkb.lisp --- libxkbcommon: keymaps and keysyms for compositor keybindings
;;;
;;; MIT license.
;;;
;;; libinput gives raw keycodes; XKB turns them into keysyms (Tab, Escape, ...)
;;; under a keymap and tracks modifier state.  We compile the default keymap and
;;; set it on each keyboard so wlroots tracks modifiers, then resolve a keycode
;;; to a keysym to recognize our shortcuts -- layout-independent, the way real
;;; compositors do it.

(in-package #:lispwc)

(cffi:define-foreign-library libxkbcommon
  (:unix (:or "libxkbcommon.so.0" "libxkbcommon.so"))
  (t (:default "libxkbcommon")))
(cffi:use-foreign-library libxkbcommon)

(cffi:defcfun ("xkb_context_new" xkb-context-new) :pointer (flags :int))
(cffi:defcfun ("xkb_context_unref" xkb-context-unref) :void (context :pointer))
(cffi:defcfun ("xkb_keymap_new_from_names" xkb-keymap-new-from-names) :pointer
  (context :pointer) (names :pointer) (flags :int))   ; names NULL => default (us)
(cffi:defcfun ("xkb_keymap_unref" xkb-keymap-unref) :void (keymap :pointer))
(cffi:defcfun ("xkb_state_key_get_one_sym" xkb-state-key-get-one-sym) :uint32
  (state :pointer) (key :uint32))

;; keysyms (xkbcommon-keysyms.h)
(defconstant +key-escape+ #xff1b)
(defconstant +key-tab+    #xff09)
(defconstant +key-f4+     #xffc1)

(defun keyboard-set-default-keymap (kbd)
  "Compile the default keymap and set it on KBD, so modifier state tracks and
keycodes resolve to keysyms."
  (let ((ctx (xkb-context-new 0)))
    (unless (cffi:null-pointer-p ctx)
      (let ((keymap (xkb-keymap-new-from-names ctx (cffi:null-pointer) 0)))
        (unless (cffi:null-pointer-p keymap)
          (wlr-keyboard-set-keymap kbd keymap)
          (xkb-keymap-unref keymap)))
      (xkb-context-unref ctx))))

(defun keyboard-keysym (kbd keycode)
  "Resolve evdev KEYCODE to an xkb keysym using KBD's state (0 if none).
libxkbcommon keycodes are evdev + 8."
  (let ((state (cffi:foreign-slot-value kbd '(:struct wlr-keyboard) 'xkb-state)))
    (if (cffi:null-pointer-p state)
        0
        (xkb-state-key-get-one-sym state (+ keycode 8)))))
