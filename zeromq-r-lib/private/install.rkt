#lang racket/base
(require (only-in "ffi.rkt" zmq-lib zmq-load-fail-reason))
(provide post-installer)

;; Hook for `raco setup`; see post-install-collection in ../info.rkt.
;; Makes no changes, just prints warning if ffi lib not found.
(define (post-installer _parent _here _user? _inst?)
  (unless zmq-lib
    (printf "\nWARNING: Cannot find libzmq foreign library (see \"ZeroMQ Requirements\").\n")
    (printf "~a\n\n" zmq-load-fail-reason)))
