;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; package.lisp --- Package for lispwc (also used by the grovel file)
;;;
;;; MIT license.

(defpackage #:lispwc
  (:use #:cl #:cffi-callback-closures)
  (:export #:run-headless #:render-color-test #:run-with-client #:run-multi #:run-drm #:run-input #:run-focus #:run-live-focus #:run-move-resize #:run-stack #:run-console #:run-cursor #:update-pointer-focus))
