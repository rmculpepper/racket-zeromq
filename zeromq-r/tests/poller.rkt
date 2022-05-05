#lang racket/base
(require racket/match
         rackunit
         (only-in ffi/unsafe void/reference-sink)
         racket/logging
         zeromq (submod zeromq unstable-draft-4.3.2)
         (submod zeromq private-testing))

;; Test that sockets (especially poller-based sockets) don't busy wait.
;; More specifically, we test that socket-based events do not get polled
;; too often.

(define TRIES 3)
(define POLLCOUNT-LIMIT 10)
(define SLEEP-S 0.25)

(define (run/detect-busy who proc)
  (test-case (format "no busy wait for ~a" who)
    (define (bad-result) (error 'test "thread completed normally: ~a" who))
    (define (run-once)
      (define completed? #f)
      (define counter1 (get-pollcount))
      (define th (thread (lambda () (proc) (set! completed? #t))))
      (or (sync/timeout SLEEP-S th) (kill-thread th))
      (define counter2 (get-pollcount))
      (values completed? (- counter2 counter1)))
    (let loop ([acc null])
      (cond [(< (length acc) TRIES)
             (define-values (completed? pollct) (run-once))
             (when completed? (bad-result))
             ;; (eprintf "~a ~s\n" who pollct)
             (cond [(> pollct POLLCOUNT-LIMIT)
                    (loop (cons pollct acc))]
                   [else (void)])]
            [else
             (error 'test "busy wait ~s: ~a" acc who)]))
    (void)))

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
