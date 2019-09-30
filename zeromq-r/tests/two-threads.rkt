#lang racket/base
(require rackunit
         zeromq)

;; Test recv in two threads doesn't busy-poll (see racket/racket#2833).

(test-case "two threads"
  (define SLEEP 0.1)
  (define ITERS 20)
  (define ENOUGH 0.75)
  (define counter 0)
  (define (count-up)
    (begin (sleep SLEEP) (sync (system-idle-evt)))
    (set! counter (add1 counter))
    (count-up))
  (define (recv) (zmq-recv (zmq-socket 'rep)))
  (define recv-threads (for/list ([i 2]) (thread recv)))
  (define counter-thread (thread count-up))
  ;; ----
  (sleep (* SLEEP ITERS))
  (kill-thread counter-thread)
  (for ([th recv-threads]) (kill-thread th))
  ;; ----
  (when (< counter (* ITERS ENOUGH))
    (error 'test "counter thread starved: counter = ~e" counter)))
