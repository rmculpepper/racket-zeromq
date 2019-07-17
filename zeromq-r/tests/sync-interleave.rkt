#lang racket/base
(require rackunit
         zeromq
         ffi/unsafe/atomic)

;; This tests whether multiple threads waiting on the same socket (and
;; same fd) wakeup if multiple reads occur.

(define msg (for/list ([i 10]) (string->bytes/utf-8 (format "~s" i))))

(define push (zmq-socket 'pair #:bind "tcp://*:5557"))
(define pull (zmq-socket 'pair #:connect "tcp://localhost:5557"))

(define readers
  (for/list ([i (in-range 100)])
    (thread (lambda ()
              (define msg* (zmq-recv* pull))
              (if (equal? msg msg*)
                  '(eprintf "READER ~s ok\n" i)
                  (eprintf "READER ~a got garbled message: ~e\n" i msg*))))))

(sleep 0.1)
(for ([i (in-range 100)])
  (zmq-send* push msg))

;;(printf "Syncing readers...\n")
(for-each sync readers)

(zmq-close push)
(zmq-close pull)
