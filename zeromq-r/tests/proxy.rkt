#lang racket/base
(require zeromq)

(define ((worker sock reply))
  (let loop ()
    (void (zmq-recv sock))
    (zmq-send sock reply)
    (loop)))
(void
 (thread (worker (zmq-socket 'rep #:connect "inproc://worker") "bonjour"))
 (thread (worker (zmq-socket 'rep #:connect "inproc://worker") "dobrý den")))

(define router (zmq-socket 'router #:bind "inproc://request"))
(define dealer (zmq-socket 'dealer #:bind "inproc://worker"))

(define (capture from-sock msg)
  (when #f (eprintf "capture: ~e said ~e\n" from-sock msg)))
(define proxy-thread
  (thread (lambda () (zmq-proxy router dealer #:capture capture))))

(define requester (zmq-socket 'req #:connect "inproc://request"))
(for ([i 10])
  (zmq-send requester "hello")
  (zmq-recv-string requester))

(zmq-close router)
(unless (sync/timeout 0.2 proxy-thread)
  (error 'test "proxy thread should have stopped"))
(zmq-close dealer)
