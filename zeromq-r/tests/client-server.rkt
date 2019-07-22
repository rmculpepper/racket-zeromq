#lang racket
(require rackunit
         zeromq)

(define PRINT? #f)

;; Server

(define srv (zmq-socket 'server #:bind "tcp://*:5555"))
(define (double-server)
  (define-values (peer msg) (zmq-peer-recv srv))
  (define n (read (open-input-bytes msg)))
  (zmq-send srv #:to peer (format "~s" (* 2 n)))
  (double-server))
(define server-thread (thread double-server))

(sleep 1)
;; Client

(define (client n close?)
  (define cli (zmq-socket 'client #:connect "tcp://localhost:5555"))
  (zmq-send cli (format "~s" n))
  (define msg (zmq-recv cli))
  (define 2n (read (open-input-bytes msg)))
  (when close? (zmq-close cli))
  (check = 2n (* 2 n) (format "client for ~s" n))
  (when PRINT? (printf "client ~s ok\n" n)))

;; Run some clients with explicit close
(define client-threads
  (for/list ([i (in-range 10)])
    (thread (lambda () (client i #t)))))
(for-each sync client-threads)

(define GC? #f)

;; Run some more clients with custodian shutdowns (and optionally GC)
(for ([i (in-range 10)])
  (eprintf "iteration ~s\n" i)
  (define client-threads2
    (for/list ([i (in-range 100)])
      (when GC? (collect-garbage))
      (thread (lambda ()
                (parameterize ((current-custodian (make-custodian)))
                  (when GC? (collect-garbage))
                  (client i #f)
                  (when GC? (collect-garbage))
                  (custodian-shutdown-all (current-custodian)))))))
  (for-each sync client-threads2))

;; Kill server
(kill-thread server-thread)
(zmq-close srv)
