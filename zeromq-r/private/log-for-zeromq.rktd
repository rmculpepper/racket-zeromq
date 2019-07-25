;; This file was created by make-log-based-eval
((require racket/match racket/format zeromq)
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((uncaught-exception-handler
  (lambda _
    (abort-current-continuation (default-continuation-prompt-tag) void)))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define responder-thread
   (thread
    (lambda ()
      (define responder (zmq-socket 'rep))
      (zmq-bind responder "tcp://*:5555")
      (let loop ()
        (define msg (zmq-recv-string responder))
        (printf "Server received: ~s\n" msg)
        (zmq-send responder "World")
        (loop)))))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define requester (zmq-socket 'req #:connect "tcp://localhost:5555"))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((for
  ((request-number (in-range 3)))
  (zmq-send requester "Hello")
  (define response (zmq-recv-string requester))
  (printf "Client received ~s (#~s)\n" response request-number))
 ((3) 0 () 0 () () (c values c (void)))
 #"Server received: \"Hello\"\nClient received \"World\" (#0)\nServer received: \"Hello\"\nClient received \"World\" (#1)\nServer received: \"Hello\"\nClient received \"World\" (#2)\n"
 #"")
((zmq-close requester) ((3) 0 () 0 () () (c values c (void))) #"" #"")
((break-thread responder-thread)
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define (zip->string zip) (~r zip #:precision 5 #:pad-string "0"))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define (random-zip) 10001) ((3) 0 () 0 () () (c values c (void))) #"" #"")
((define publisher-thread
   (thread
    (lambda ()
      (define publisher (zmq-socket 'pub #:bind "tcp://*:5556"))
      (let loop ()
        (define zip (zip->string (random-zip)))
        (define temp (- (random 215) 80))
        (define rhumid (+ (random 50) 10))
        (zmq-send publisher (format "~a ~a ~a" zip temp rhumid))
        (loop)))))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define subscriber (zmq-socket 'sub #:connect "tcp://localhost:5556"))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define myzip (zip->string (random-zip)))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((printf "Subscribing to ZIP code ~a only\n" myzip)
 ((3) 0 () 0 () () (c values c (void)))
 #"Subscribing to ZIP code 10001 only\n"
 #"")
((zmq-subscribe subscriber myzip)
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define total-temp
   (for/sum
    ((update-number (in-range 10)))
    (define msg (zmq-recv-string subscriber))
    (define temp (let ((in (open-input-string msg))) (read in) (read in)))
    (printf "Client got temperature update #~s: ~s\n" update-number temp)
    temp))
 ((3) 0 () 0 () () (c values c (void)))
 #"Client got temperature update #0: 40\nClient got temperature update #1: 53\nClient got temperature update #2: 130\nClient got temperature update #3: 22\nClient got temperature update #4: -77\nClient got temperature update #5: -4\nClient got temperature update #6: 85\nClient got temperature update #7: -2\nClient got temperature update #8: 100\nClient got temperature update #9: 96\n"
 #"")
((printf
  "Average temperature for ZIP code ~s was ~s\n"
  myzip
  (~r (/ total-temp 10)))
 ((3) 0 () 0 () () (c values c (void)))
 #"Average temperature for ZIP code \"10001\" was \"44.3\"\n"
 #"")
((zmq-close subscriber) ((3) 0 () 0 () () (c values c (void))) #"" #"")
((break-thread publisher-thread)
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define (ventilator go-sema)
   (define sender (zmq-socket 'push #:bind "tcp://*:5557"))
   (define sink (zmq-socket 'push #:connect "tcp://localhost:5558"))
   (semaphore-wait go-sema)
   (zmq-send sink "0")
   (define total-msec
     (for/fold
      ((total 0))
      ((task-number (in-range 100)))
      (define workload (add1 (random 100)))
      (zmq-send sender (format "~s" workload))
      (+ total workload)))
   (printf "Total expected cost: ~s msec\n" total-msec)
   (zmq-close sender)
   (zmq-close sink))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define (worker)
   (define receiver (zmq-socket 'pull #:connect "tcp://localhost:5557"))
   (define sender (zmq-socket 'push #:connect "tcp://localhost:5558"))
   (let loop ()
     (define s (zmq-recv-string receiver))
     (sleep (/ (read (open-input-string s)) 1000))
     (zmq-send sender "")
     (loop)))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((define (sink)
   (define receiver (zmq-socket 'pull #:bind "tcp://*:5558"))
   (void (zmq-recv receiver))
   (time (for ((task-number (in-range 100))) (void (zmq-recv receiver))))
   (zmq-close receiver))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((let ()
   (define go-sema (make-semaphore 0))
   (define sink-thread (thread sink))
   (define ventilator-thread (thread (lambda () (ventilator go-sema))))
   (define worker-threads (for/list ((i 10)) (thread worker)))
   (begin (sleep 1) (semaphore-post go-sema))
   (void (sync sink-thread)))
 ((3) 0 () 0 () () (c values c (void)))
 #"Total expected cost: 5291 msec\ncpu time: 292 real time: 623 gc time: 0\n"
 #"")
((define msg (zmq-message "hello world"))
 ((3) 0 () 0 () () (c values c (void)))
 #""
 #"")
((match msg ((zmq-message frames) frames))
 ((3) 0 () 0 () () (c values c (c (u . #"hello world"))))
 #""
 #"")
