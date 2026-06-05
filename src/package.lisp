;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; package.lisp --- Package for lispwc (also used by the grovel file)
;;;
;;; MIT license.

(defpackage #:lispwc
  (:use #:cl #:cffi-callback-closures)
  (:export #:run-headless #:render-color-test #:run-with-client))
