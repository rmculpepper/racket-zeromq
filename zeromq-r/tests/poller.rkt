#lang racket/base
(require racket/match
         (only-in ffi/unsafe void/reference-sink)
         racket/logging
         zeromq (submod zeromq unstable-draft-4.3.2)
         (submod zeromq private-logger))

;; Test that sockets (especially poller-based sockets) don't busy wait.

(define (run/intercept proc intercept)
  (define (intercept* logv)
    (match-define (vector level message _ topic) logv)
    (intercept level topic message))
  (with-intercepted-logging intercept* proc 'debug 'zmq #:logger zmq-logger))

(define (run/detect-busy who proc)
  (define result void)
  (define (proc*)
    (run/intercept
     (lambda ()
       (proc)
       (set! result (lambda () (error 'test "thread completed normally: ~a" who))))
     (let ([counter 0])
       (lambda (level topic message)
         (when (regexp-match? #rx"(wait; fd)|(poller is ready)" message)
           ;; (eprintf "log ~s: got ~s, ~s, ~s\n" counter level topic message)
           (set! counter (add1 counter))
           (when (> counter 10)
             (set! result (lambda () (error 'test "busy wait: ~a" who)))
             (kill-thread th)))))))
  (define th (thread proc*))
  (or (sync/timeout 0.25 th) (kill-thread th))
  (result))

;; ----

(run/detect-busy "pair send"
 (lambda ()
   (define s (zmq-socket 'pair))
   (zmq-send s "hello")))

(run/detect-busy "pair recv"
 (lambda ()
   (define s (zmq-socket 'pair))
   (zmq-recv s)))

(run/detect-busy "req send"
 (lambda ()
   (define s (zmq-socket 'req))
   (zmq-send s "hello")))

(run/detect-busy "rep recv"
 (lambda ()
   (define s (zmq-socket 'rep))
   (zmq-recv s)))

(run/detect-busy "push send"
 (lambda ()
   (define s (zmq-socket 'push))
   (zmq-send s "hello")))

(run/detect-busy "pull recv"
 (lambda ()
   (define s (zmq-socket 'pull))
   (zmq-recv s)))

;; ----

(when zmq-draft-available?

  (run/detect-busy "client send"
   (lambda ()
     (define s (zmq-draft-socket 'client))
     (zmq-send s "hello")))

  (run/detect-busy "client bind send"
   (lambda ()
     (define s (zmq-draft-socket 'client #:bind "tcp://*:5559"))
     (zmq-send s "hello")))

  (run/detect-busy "server recv"
   (lambda ()
     (define s (zmq-draft-socket 'server))
     (zmq-recv s)))

  (run/detect-busy "scatter send"
   (lambda ()
     (define s (zmq-draft-socket 'scatter))
     (zmq-send s "hello")))

  (run/detect-busy "scatter bind send"
   (lambda ()
     (define s (zmq-draft-socket 'scatter #:bind "tcp://*:5558"))
     (zmq-send s "hello")))

  (run/detect-busy "gather recv"
   (lambda ()
     (define s (zmq-draft-socket 'gather))
     (zmq-recv s)))

  (run/detect-busy "gather bind recv"
   (lambda ()
     (define s (zmq-draft-socket 'gather #:bind "tcp://*:5557"))
     (zmq-recv s))))

(when zmq-draft-available?
  (define ss (zmq-draft-socket 'server #:bind "tcp://*:5556"))
  (sync/timeout 0.2 ss)
  (define sc (zmq-draft-socket 'client #:connect "tcp://localhost:5556"))
  (zmq-send sc "hello!")
  (run/detect-busy "ready socket removed from poller"
    (lambda ()
      (define s2 (zmq-draft-socket 'server))
      (zmq-recv s2)))
  (void/reference-sink ss sc))
