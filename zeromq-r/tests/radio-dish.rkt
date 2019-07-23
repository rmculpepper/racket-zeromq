#lang racket
(require racket/match
         rackunit
         zeromq
         (submod zeromq unstable-draft-4.3.2))

(unless zmq-draft-available?
  (printf "draft API support not available\n")
  (exit))

(define PRINT? #f)

;; This tests radio/dish sockets with a very high-speed game of
;; bingo. The first client to hear their group/number combination 10
;; times wins!

;; Dishes (clients)

(define WIN 10)
(define (client group n)
  (define n-bytes (string->bytes/utf-8 (format "~a" n)))
  (define dish (zmq-draft-socket 'dish #:connect "tcp://localhost:5555" #:join group))
  (let loop ([count 0])
    (cond [(< count WIN)
           (match-define (zmq-message (list frame) #:group (== group)) (zmq-recv-message dish))
           (loop (if (equal? frame n-bytes) (add1 count) count))]
          [else (when PRINT? (printf "client ~a/~a wins!\n" group n))])))
(define client-threads
  (for*/list ([group (in-list (list #"left" #"right"))] [i (in-range 100)])
    (thread (lambda () (client group i)))))

;; Radio

(sleep 1)
(define radio (zmq-draft-socket 'radio #:bind "tcp://*:5555"))
(define radio-thread
  (thread
   (lambda ()
     (let loop ([i 0])
       (when (and (zero? (remainder i 500)) (> i 0))
         (when PRINT? (printf "radio has sent ~s numbers\n" i)))
       (when (< i +inf.0) ;;#e1e4
         (zmq-send-message radio (zmq-message (format "~a" (random 100)) #:group #"left"))
         (zmq-send-message radio (zmq-message (format "~a" (random 100)) #:group #"right"))
         (loop (add1 i)))))))

;; Finish

(void (apply sync client-threads)) ;; only need one winner
(kill-thread radio-thread)
(zmq-close radio)
