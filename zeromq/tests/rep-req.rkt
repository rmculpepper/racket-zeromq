#lang racket
(require rackunit
         zeromq)

(define PRINT? #f)

;; Server

(define rep (zmq-socket 'rep #:bind "tcp://*:5554"))
(define (double-server)
  (define msg (zmq-recv rep))
  (define n (read (open-input-bytes msg)))
  (zmq-send rep (format "~s" (* 2 n)))
  (double-server))
(define server-thread (thread double-server))

;; Client

(define (client n close?)
  (define req (zmq-socket 'req #:connect "tcp://localhost:5554"))
  (zmq-send req (format "~s" n))
  (define msg (zmq-recv req))
  (define 2n (read (open-input-bytes msg)))
  (when close? (zmq-close req))
  (check = 2n (* 2 n) (format "client for ~s" n))
  (when PRINT? (printf "client ~s ok\n" n)))

;; Run some clients with explicit close
(define client-threads
  (for/list ([i (in-range 100)])
    (thread (lambda () (client i #t)))))
(for-each sync client-threads)

;; Run some more clients with custodian shutdowns
(for ([i (in-range 10)])
  (define client-threads2
    (for/list ([i (in-range 10)])
      (collect-garbage)
      (thread (lambda ()
                (parameterize ((current-custodian (make-custodian)))
                  (collect-garbage)
                  (client i #f)
                  (collect-garbage)
                  (custodian-shutdown-all (current-custodian)))))))
  (for-each sync client-threads2))

;; Kill server
(kill-thread server-thread)
(zmq-close rep)
