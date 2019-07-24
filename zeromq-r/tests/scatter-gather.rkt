#lang racket
(require racket/match
         rackunit
         zeromq
         (submod zeromq unstable-draft-4.3.2))

(unless zmq-draft-available?
  (printf "draft API support not available\n")
  (exit))

(define PRINT? #f)

;; Server

(define scatter-threads
  (for/list ([i 10])
    (thread
     (lambda ()
       (define scatter (zmq-draft-socket 'scatter #:bind (format "tcp://*:~a" (+ 5560 i))))
       (for ([j (in-range 100)])
         (zmq-send scatter (format "~s" (list i j))))))))

;; Client

(define gather-boxes (for/list ([i 10]) (box 0)))

(define gather-threads
  (for/list ([gather-box (in-list gather-boxes)])
    (thread
     (lambda ()
       (define gather (zmq-draft-socket 'gather
                                        #:connect (for/list ([i (in-range 10)])
                                                    (format "tcp://localhost:~a" (+ 5560 i)))))
       (let loop ()
         (define msg (zmq-recv gather))
         (match (read (open-input-bytes msg))
           [(list from num)
            (set-box! gather-box (+ (unbox gather-box) num))])
         (loop))))))

(for-each sync scatter-threads)
(sleep 0.1)

(check-equal? (for/sum ([b (in-list gather-boxes)]) (unbox b))
              (for*/sum ([i 10] [j 100]) j))
