#lang racket/base
(require ffi/unsafe
         ffi/unsafe/atomic
         ffi/unsafe/custodian
         "private/ffi.rkt")
(provide (all-defined-out))

;; There is one implicit context created on demand, only finalized
;; when the namespace goes away.

;; A Context is (context _zmq_ctx-pointer Real)
;; Destroying will not block if (current-inexact-milliseconds) >= keepuntil.
(struct context (ptr [keepuntil #:mutable]))

(define the-ctx #f)

;; get-ctx : -> Context
;; PRE: called in atomic mode
(define (get-ctx)
  (unless the-ctx
    (define ctx (zmq_ctx_new))
    (register-finalizer ctx
      (lambda (ctx)
        (zmq_ctx_destroy ctx)))
    (set! the-ctx (zmq_ctx_new)))
  the-ctx)

;; ============================================================

;; A Socket is (socket (U _zmq_socket-pointer #f) _zmq_msg-pointer Sema)
(struct socket ([ptr #:mutable] msg sema)
  #:reflection-name 'zmq-socket)

(define (socket-ptr* who sock)
  (let ([ptr (socket-ptr sock)])
    (unless ptr (error who "socket is closed"))
    ptr))

;; zmq-socket : -> Socket
(define (zmq-socket type)
  (start-atomic)
  (define ctx (get-ctx))
  (define ptr (zmq_socket ctx type))
  (unless ptr
    (end-atomic)
    (error 'zmq-socket "could not create socket\n  type: ~e~a" type (errno-lines)))
  (define msg (cast (malloc 'atomic-interior _zmq_msg) _pointer _zmq_msg-pointer))
  (define sock (socket ptr msg (make-semaphore 1)))
  (register-finalizer-and-custodian-shutdown sock
    (lambda (sock) (*close 'zmq-socket-finalizer sock)))
  (end-atomic)
  ;; (zmq-set-socket-option sock 'linger 1000)
  sock)

(define (zmq-get-socket-option sock option
                               #:who [who 'zmq-get-socket-option])
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* who sock))
      (let ([v (cond [(memq option integer-socket-options)
                      (zmq_getsockopt/int ptr option)]
                     [(memq option bytes-socket-options)
                      (zmq_getsockopt/bytes* ptr option)])])
        (unless v
          (error 'zmq-get-socket-option "error getting socket option\n  option: ~e~a"
                 option (errno-lines)))
        v))))

(define (zmq-set-socket-option sock option value
                               #:who [who 'zmq-set-socket-option])
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* who sock))
      (let ([s (cond [(exact-integer? value)
                      (zmq_setsockopt/int ptr option value)]
                     [(bytes? value)
                      (zmq_setsockopt/bytes ptr option value)])])
        (unless (zero? s)
          (error who "error setting socket option\n  option: ~e\n  value: ~e~a"
                 option value (errno-lines)))
        (void)))))

(define (zmq-connect sock . addrs)
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* 'zmq-connect sock))
      (for ([addr (in-list addrs)])
        (let ([s (zmq_connect ptr addr)])
          (unless (zero? s)
            (error 'zmq-connect "error connecting socket\n  address: ~e~a" addr (errno-lines)))
          (void))))))

(define (zmq-bind sock . addrs)
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* 'zmq-connect sock))
      (for ([addr (in-list addrs)])
        (let ([s (zmq_bind ptr addr)])
          (unless (zero? s)
            (error 'zmq-bind "error binding socket\n  address: ~e~a" addr (errno-lines)))
          (void))))))

(define (zmq-close sock)
  (call-as-atomic
   (lambda ()
     (*close 'zmq-close sock))))

(define (*close who sock)
  (let ([ptr (socket-ptr sock)])
    (when ptr
      (set-socket-ptr! sock #f)
      (let ([s (zmq_close ptr)])
        (unless (zero? s)
          (error 'zmq-close "error closing socket~a" (errno-lines)))))))

(define (errno-lines)
  (format "\n  errno: ~s\n  error: ~.a" (saved-errno) (zmq_strerror (saved-errno))))

;; ============================================================

;; A MsgPart is (U String Bytes)

;; zmq-send : Socket MsgPart ... -> Void
(define (zmq-send sock part1 . parts)
  (define frames
    (for/list ([part (in-list (cons part1 parts))])
      (if (string? part) (string->bytes/utf-8 part) part)))
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* 'zmq-send sock))
      (define (sendframe frame n options)
        (let ([s (zmq_send ptr (car frames) options)])
          (cond [(>= s 0) (void)]
                [(= (saved-errno) EAGAIN)
                 (eprintf "got EAGAIN, retrying\n")
                 (sleep 0.001)
                 (sendframe frame n options)]
                ;; [(= (saved-errno) EINTR) ...]
                [else
                 (error 'zmq-send "error sending message\n  frame: ~s of ~s~a"
                        n (length frames) (errno-lines))])))
      (let loop ([frames frames] [n 1])
        (cond [(null? (cdr frames)) ;; last frame
               (sendframe (car frames) n '())]
              [else
               (sendframe (car frames) n '(ZMQ_SENDMORE))
               (loop (cdr frames) (add1 n))])))))

(define (zmq-recv* sock
                   #:who [who 'zmq-recv*])
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* who sock))
      (define msg (socket-msg sock))
      (define (recvframe n)
        (let ([s (zmq_msg_init msg)])
          (unless (zero? s)
            (error who "error initializing message~a" (errno-lines))))
        (let recvloop ()
          (let ([s (zmq_msg_recv msg ptr '())])
            (cond [(>= s 0)
                   (define size (zmq_msg_size msg))
                   (define frame (make-bytes size))
                   (memcpy frame (zmq_msg_data msg) size)
                   (define more? (zmq_msg_more msg))
                   (zmq_msg_close msg)
                   (values frame more?)]
                  [(= (saved-errno) EAGAIN)
                   (eprintf "got EAGAIN, retrying\n")
                   (sleep 0.001)
                   (recvloop)]
                  [else
                   (zmq_msg_close msg)
                   (error who "error receiving message\n  frame: ~s~a" n (errno-lines))]))))
      (let loop ([rframes null] [n 1])
        (define-values (frame more?) (recvframe n))
        (let ([rframes (cons frame rframes)])
          (if more?
              (loop rframes (add1 n))
              (reverse rframes)))))))

(define (zmq-recv sock)
  (define frames (zmq-recv* sock #:who 'zmq-recv))
  (cond [(and (pair? frames) (null? (cdr frames)))
         (car frames)]
        [else
         (error 'zmq-recv "received multi-frame message\n  frames: ~s" (length frames))]))
