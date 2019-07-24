#lang racket/base
(require rackunit
         zeromq
         (submod zeromq unstable-draft-4.3.2))

;; Tests for error reporting. Each test is labeled with where the call
;; to error occurs.

(define-syntax-rule (rxs rx ...)
  (lambda (e)
    (and (exn? e)
         (not (regexp-match? #rx"format string" (exn-message e)))
         (regexp-match? rx (exn-message e)) ...)))

;; ----------------------------------------

;; zmq-socket
;; FIXME: could not create socket (how to provoke?)

;; -close
;; FIXME: error closing socket (how to provoke?)

;; call-with-socket-ptr
(let ()
  (define s (zmq-socket 'pair))
  (zmq-close s)
  (check-exn (rxs #rx"socket is closed\n  socket:")
             (lambda () (zmq-connect s "tcp://localhost:12345"))))

;; zmq-get-option, zmq-set-option
(let ()
  (define s (zmq-socket 'pair))
  (check-exn (rxs #rx"socket option is not readable")
             (lambda () (zmq-get-option s 'subscribe)))
  (check-exn (rxs #rx"socket option is not writable")
             (lambda () (zmq-set-option s 'rcvmore 1)))
  (check-exn (rxs #rx"socket option is not writable")
             (lambda () (zmq-set-option s 'conflate 1)))
  (check-exn (rxs #rx"bad value for option")
             (lambda () (zmq-set-option s 'identity 12)))
  (check-exn (rxs #rx"error setting socket option")
             (lambda () (zmq-set-option s 'immediate -12))))

;; bind/connect, unbind/disconnect
(let ()
  (define s (zmq-socket 'pair))
  (check-exn (rxs #rx"error connecting socket")
             (lambda () (zmq-connect s "inproc://")))
  (check-exn (rxs #rx"error unbinding socket")
             (lambda () (zmq-unbind s "inproc://didntbind"))))

;; *subscribe
(let ()
  (define s (zmq-socket 'pair)) ;; can't subscribe
  (check-exn (rxs #rx"subscribe error")
             (lambda () (zmq-subscribe s "x"))))

;; *join
(when zmq-draft-available?
  (define s (zmq-socket 'pair)) ;; can't join
  (check-exn (rxs #rx"join error")
             (lambda () (zmq-join s #"x"))))

;; zmq-message, etc
(let ()
  (check-exn (rxs #rx"cannot have both a routing-id and a group")
             (lambda () (zmq-message "hello" #:routing-id 1 #:group #"group"))))

;; zmq-send-message
(let ()
  (define s (zmq-socket 'push))
  (define t (thread (lambda () (zmq-send s "a" "b" "c"))))
  (sync (system-idle-evt)) ;; wait for t to block
  (kill-thread t)
  (check-exn (rxs "socket is permanently locked for writes")
             (lambda () (zmq-send s "d"))))

;; make-send-error
(let ()
  (define s (zmq-socket 'rep)) ;; can't initiate conversation
  (check-exn (rxs #rx"error sending message")
             (lambda () (zmq-send s "hello"))))

;; zmq-recv
(let ()
  (define p1 (zmq-socket 'pair #:bind "inproc://pair"))
  (define p2 (zmq-socket 'pair #:connect "inproc://pair"))
  (zmq-send p1 "a" "b" "c")
  (check-exn (rxs #rx"received multi-frame message")
             (lambda () (zmq-recv p2))))

;; make-recv-error
(let ()
  (define s (zmq-socket 'req)) ;; must send message first
  (check-exn (rxs #rx"error receiving frame")
             (lambda () (zmq-recv s))))
