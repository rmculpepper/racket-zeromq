#lang racket/base
(require rackunit
         zeromq
         ffi/unsafe/atomic)

;; This tests whether multiple threads waiting on the same socket (and
;; same fd) wakeup if multiple reads occur.

(define pub (zmq-socket 'pub #:bind "tcp://*:5557"))
(define sub (zmq-socket 'sub #:connect "tcp://localhost:5557"))
(zmq-subscribe sub "msg")

(define readers
  (for/list ([i (in-range 1000)])
    (thread (lambda () (zmq-recv sub)))))

(sleep 0.1)
(for ([i (in-range 1000)])
  (zmq-send pub (format "msg ~s" i)))

;;(printf "Syncing readers...\n")
(for-each sync readers)

(zmq-close pub)
(zmq-close sub)
