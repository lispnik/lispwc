;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; wayland.lisp --- libwayland-server bindings + the listener-closure helper
;;;
;;; MIT license.

(in-package #:lispwc)

(cffi:define-foreign-library libwayland-server
  (:unix (:or "libwayland-server.so.0" "libwayland-server.so"))
  (t (:default "libwayland-server")))
(cffi:use-foreign-library libwayland-server)

(cffi:defcfun ("wl_display_create" wl-display-create) :pointer)
(cffi:defcfun ("wl_display_get_event_loop" wl-display-get-event-loop) :pointer
  (display :pointer))
(cffi:defcfun ("wl_display_run" wl-display-run) :void (display :pointer))
(cffi:defcfun ("wl_display_terminate" wl-display-terminate) :void (display :pointer))
(cffi:defcfun ("wl_display_destroy_clients" wl-display-destroy-clients) :void (display :pointer))
(cffi:defcfun ("wl_display_destroy" wl-display-destroy) :void (display :pointer))
(cffi:defcfun ("wl_display_add_socket_auto" wl-display-add-socket-auto) :string
  (display :pointer))
;; wl_list_insert/remove are exported; wl_signal_add itself is static inline.
(cffi:defcfun ("wl_list_insert" wl-list-insert) :void (list :pointer) (elm :pointer))
(cffi:defcfun ("wl_list_remove" wl-list-remove) :void (elm :pointer))
;; event-loop timer (to bound a run that has no frame loop)
(cffi:defcfun ("wl_event_loop_add_timer" wl-event-loop-add-timer) :pointer
  (loop :pointer) (func :pointer) (data :pointer))
(cffi:defcfun ("wl_event_source_timer_update" wl-event-source-timer-update) :int
  (source :pointer) (ms :int))

(defvar *listeners* '()
  "Keeps wl_listener structs and their callbacks reachable for the run's life.")

(defvar *dead-listeners* '()
  "(listener . cb) pairs unlinked from their signal but not yet freed.  Freeing a
libffi closure while it is executing is a use-after-free, and a destroy notify is
itself a closure -- so UNLINK-LISTENER queues here and REAP-LISTENERS does the
free later, from a frame/idle, never from inside the callback being freed.")

(defun add-listener (signal notify-fn)
  "Register NOTIFY-FN, a (lambda (listener data) ...), on the wl_signal at the
foreign pointer SIGNAL.  This is wl_signal_add reimplemented on the exported
wl_list_insert, because wl_signal_add itself is static inline.  NOTIFY-FN is a
Lisp closure -- it can close over whatever context the handler needs, replacing
C's wl_container_of dance."
  (let ((listener (cffi:foreign-alloc '(:struct wl-listener)))
        (cb (make-foreign-callback notify-fn :void '(:pointer :pointer))))
    (setf (cffi:foreign-slot-value listener '(:struct wl-listener) 'notify) cb)
    ;; wl_signal_add: wl_list_insert(signal->listener_list.prev, &listener->link)
    ;; signal->listener_list.prev is the first pointer at SIGNAL; &listener->link
    ;; is LISTENER itself (link is the first member).
    (wl-list-insert (cffi:mem-ref signal :pointer) listener)
    (push (cons listener cb) *listeners*)
    listener))

(defun listener-callback (listener)
  "The foreign-callback object backing LISTENER, or NIL."
  (cdr (assoc listener *listeners* :test #'cffi:pointer-eq)))

(defun unlink-listener (listener)
  "Unlink LISTENER from its signal NOW -- this must happen before the object
that owns the signal is freed -- and queue its trampoline for REAP-LISTENERS to
free at a safe point.  Safe to call from inside a notify callback (including the
listener's own), because it does not free the closure here."
  (ignore-errors (wl-list-remove listener))     ; &listener->link == listener
  (let ((entry (assoc listener *listeners* :test #'cffi:pointer-eq)))
    (when entry
      (setf *listeners* (remove entry *listeners*))
      (push entry *dead-listeners*))))

(defun reap-listeners ()
  "Free the trampolines queued by UNLINK-LISTENER.  Call from a frame or idle,
never from inside the callback being freed."
  (dolist (e *dead-listeners*)
    (ignore-errors (free-foreign-callback (cdr e)))
    (ignore-errors (cffi:foreign-free (car e))))
  (setf *dead-listeners* '()))

(defun free-listeners ()
  "Unlink every listener from its signal (wlroots asserts the lists are empty at
backend finish) and release its memory + callback."
  (dolist (l *listeners*)
    (ignore-errors (wl-list-remove (car l)))   ; &listener->link == listener
    (ignore-errors (free-foreign-callback (cdr l)))
    (ignore-errors (cffi:foreign-free (car l))))
  (setf *listeners* '())
  (reap-listeners))
