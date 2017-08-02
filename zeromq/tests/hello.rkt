#lang racket
(require rackunit
         zeromq)

(define hello-server-thread
  (thread
   (lambda ()
     (define s (zmq-socket 'rep #:bind "tcp://*:5555"))
     (printf "server = ~v\n" s)
     (let loop ()
       (define msg (zmq-recv s))
       ;; (printf "S got: ~v\n" msg)
       (cond [(regexp-match #rx#"^message ([0-9]+) " msg)
              => (lambda (m)
                   (zmq-send s (format "hello, ~a" (cadr m)))
                   (loop))]
             [(equal? msg #"quit")
              (zmq-send s "quitting")
              (void)]
             [else
              (zmq-send s "huh?")
              (loop)])))))

(define (hello-client id)
  (define s (zmq-socket 'req #:connect "tcp://localhost:5555"))
  (for ([i (in-range 10)])
    (zmq-send s (format "message ~s ~s" id i))
    (check-equal? (zmq-recv-string s) (format "hello, ~s" id))))

(for-each sync
          (for/list ([id (in-range 10)])
            (thread (lambda () (hello-client id)))))

(define q (zmq-socket 'req #:connect "tcp://localhost:5555"))
(zmq-send q "quit")

(void (sync hello-server-thread))
