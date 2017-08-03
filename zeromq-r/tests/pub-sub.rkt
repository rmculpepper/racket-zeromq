#lang racket
(require rackunit
         zeromq)

(define PRINT? #f)

;; Server sends numbers 0-999 in a continuous loop, prefixed by last digit.

(define pub (zmq-socket 'pub #:bind "tcp://*:5556"))
(define (publisher-loop i)
  (zmq-send pub (format "~a ~a" (remainder i 10) i))
  (publisher-loop (remainder (add1 i) 1000)))
(define publisher-thread (thread (lambda () (publisher-loop 0))))

;; Client

(define (client digit)
  (define sub (zmq-socket 'sub #:connect "tcp://localhost:5556"))
  (zmq-subscribe sub (format "~a " digit))
  (define msg-total (for/sum ([i (in-range 100)])
                      (define msg (zmq-recv sub))
                      (let ([in (open-input-bytes msg)]) (read in) (read in))))
  (define comp-total (for/sum ([n (in-range digit 1000 10)]) n))
  (zmq-close sub)
  (check = msg-total comp-total (format "total for digit ~s" digit))
  (when PRINT? (printf "Client ~s ok, total = ~s\n" digit msg-total)))

(define client-threads
  (for/list ([digit (in-range 10)])
    (thread (lambda () (client digit)))))

(for-each sync client-threads)

(kill-thread publisher-thread)
(zmq-close pub)
