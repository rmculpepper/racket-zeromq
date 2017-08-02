#lang racket/base
(require racket/struct
         ffi/unsafe
         ffi/unsafe/atomic
         ffi/unsafe/custodian
         "private/ffi.rkt")
(provide (all-defined-out))

;; There is one implicit context created on demand, only finalized
;; when the namespace goes away.

(define the-ctx #f)

;; get-ctx : -> Context
;; PRE: called in atomic mode
(define (get-ctx)
  (unless the-ctx
    (define ctx (zmq_ctx_new))
    (register-finalizer ctx zmq_ctx_destroy)
    (set! the-ctx ctx))
  the-ctx)

;; ============================================================

;; A Socket is (socket (U _zmq_socket-pointer #f (Listof CommEntry)) _zmq_msg-pointer Sema)
;; The zmq_msg is kept uninitialized/closed except during zmq-recv.
;; A CommEntry is (cons 'bind String) | (cons 'connect String) | (cons 'subscribe Bytes)
(struct socket ([ptr #:mutable] msg sema [comms #:mutable])
  #:reflection-name 'zmq-socket
  #:property prop:custom-write
  (make-constructor-style-printer
   (lambda (s) 'zmq-socket)
   (lambda (s)
     (define (comms-get comms type)
       (for/list ([c (in-list comms)] #:when (eq? (car c) type)) (cdr c)))
     (define-values (type identity)
       (call-as-atomic
        (lambda ()
          (cond [(socket-ptr s)
                 => (lambda (ptr)
                      (values (cast (zmq_getsockopt/int ptr 'type) _int _zmq_socket_type)
                              (zmq_getsockopt/bytes ptr 'identity)))]
                [else (values 'closed #f)]))))
     (define binds (comms-get (socket-comms s) 'bind))
     (define connects (comms-get (socket-comms s) 'connect))
     (append (list type)
             (if (and identity (not (equal? identity #""))) (list (pp:lit "#:identity") identity) '())
             (if (pair? binds) (list (pp:lit "#:bind") binds) '())
             (if (pair? connects) (list (pp:lit "#:connect") connects) '())))))

(struct pp:lit (str)
  #:property prop:custom-write (lambda (self out mode) (write-string (pp:lit-str self) out)))

(define (socket-ptr* who sock)
  (let ([ptr (socket-ptr sock)])
    (unless ptr (error who "socket is closed"))
    ptr))

(define (zmq-socket? v) (socket? v))

;; zmq-socket : -> Socket
(define (zmq-socket type
                    #:identity [identity #f]
                    #:bind [bind-addrs null]
                    #:connect [connect-addrs null]
                    #:subscribe [subscriptions null])
  (start-atomic)
  (define ctx (get-ctx))
  (define ptr (zmq_socket ctx type))
  (unless ptr
    (end-atomic)
    (error 'zmq-socket "could not create socket\n  type: ~e~a" type (errno-lines)))
  (define msg (new-zmq_msg))
  (define sock (socket ptr msg (make-semaphore 1) null))
  (register-finalizer-and-custodian-shutdown sock
    (lambda (sock) (*close 'zmq-socket-finalizer sock)))
  (end-atomic)
  ;; Set options, etc.
  (zmq-set-option sock 'linger 1000)
  (when identity (zmq-set-option sock 'identity identity)) ;; FIXME: contract
  (apply zmq-subscribe sock (coerce->list subscriptions))
  (apply zmq-bind sock (coerce->list bind-addrs))
  (apply zmq-connect sock (coerce->list connect-addrs))
  sock)

(define (zmq-get-option sock option
                        #:who [who 'zmq-get-option])
  ;; FIXME: move check outside
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* who sock))
      (let ([v (cond [(memq option integer-socket-options)
                      (zmq_getsockopt/int ptr option)]
                     [(memq option bytes-socket-options)
                      (zmq_getsockopt/bytes ptr option)])])
        (unless v
          (error who "error getting socket option\n  option: ~e~a"
                 option (errno-lines)))
        v))))

(define (zmq-set-option sock option value
                        #:who [who 'zmq-set-option])
  ;; FIXME: add check outside
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
  (when (pair? addrs)
    (call-with-semaphore (socket-sema sock)
      (lambda ()
        (define ptr (socket-ptr* 'zmq-connect sock))
        (for ([addr (in-list addrs)])
          (let ([s (zmq_connect ptr addr)])
            (unless (zero? s)
              (error 'zmq-connect "error connecting socket\n  address: ~e~a" addr (errno-lines)))
            ;; FIXME: need to check last_endpoint on some kinds of connections
            (set-socket-comms! sock (cons (cons 'connect addr) (socket-comms sock)))))))))

(define (zmq-bind sock . addrs)
  (when (pair? addrs)
    (call-with-semaphore (socket-sema sock)
      (lambda ()
        (define ptr (socket-ptr* 'zmq-bind sock))
        (for ([addr (in-list addrs)])
          (let ([s (zmq_bind ptr addr)])
            (unless (zero? s)
              (error 'zmq-bind "error binding socket\n  address: ~e~a" addr (errno-lines)))
            ;; FIXME: need to check last_endpoint on some kinds of binds
            (set-socket-comms! sock (cons (cons 'bind addr) (socket-comms sock)))))))))

(define (zmq-close sock)
  (call-as-atomic
   (lambda ()
     (*close 'zmq-close sock))))

(define wait-fd-is-socket? (eq? (system-type) 'windows))

;; PRE: in atomic mode
(define (*close who sock)
  (let ([ptr (socket-ptr sock)])
    (when ptr
      (set-socket-ptr! sock #f)
      (define fd (zmq_getsockopt/int ptr 'fd))
      (scheme_fd_to_semaphore fd MZFD_REMOVE wait-fd-is-socket?)
      (let ([s (zmq_close ptr)])
        (unless (zero? s)
          (error 'zmq-close "error closing socket~a" (errno-lines)))))))

(define (zmq-subscribe sock . subs)
  (*subscribe 'zmq-subscribe 'subscribe sock subs))
(define (zmq-unsubscribe sock . subs)
  (*subscribe 'zmq-unsubscribe 'unsubscribe sock subs))

(define (*subscribe who mode sock subs)
  (when (pair? subs)
    (call-with-semaphore (socket-sema sock)
      (lambda ()
        (define ptr (socket-ptr* who sock))
        (for ([sub (in-list subs)])
          (let ([s (zmq_setsockopt/bytes ptr mode sub)])
            (unless (zero? s)
              (error who "error~a" (errno-lines)))))))))

(define (errno-lines)
  (format "\n  errno: ~s\n  error: ~.a" (saved-errno) (zmq_strerror (saved-errno))))

(define (coerce->list x) (if (list? x) x (list x)))
(define (coerce->bytes x) (if (string? x) (string->bytes/utf-8 x) x))

;; ============================================================

;; A MsgPart is (U String Bytes)

;; zmq-send : Socket MsgPart ... -> Void
(define (zmq-send sock part1 . parts)
  (define frames (map coerce->bytes (cons part1 parts)))
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* 'zmq-send sock))
      (define (sendframe frame n options)
        (let ([s (zmq_send ptr (car frames) options)])
          (cond [(>= s 0) (void)]
                [(or (= (saved-errno) EAGAIN)
                     (= (saved-errno) EINTR))
                 (*wait ptr ZMQ_POLLOUT)
                 (sendframe frame n options)]
                [else
                 (error 'zmq-send "error sending message\n  frame: ~s of ~s~a"
                        n (length frames) (errno-lines))])))
      (let loop ([frames frames] [n 1])
        (cond [(null? (cdr frames)) ;; last frame
               (sendframe (car frames) n '(ZMQ_DONTWAIT))]
              [else
               (sendframe (car frames) n '(ZMQ_DONTWAIT ZMQ_SENDMORE))
               (loop (cdr frames) (add1 n))])))))

(define (*wait ptr event)
  (let loop ()
    (let ([events (zmq_getsockopt/int ptr 'events)])
      (unless (bitwise-and events event)
        (define fd (zmq_getsockopt/int ptr 'fd))
        (sync (scheme_fd_to_semaphore fd MZFD_CREATE_READ #f))
        (loop)))))

(define (zmq-recv* sock
                   #:who [who 'zmq-recv*])
  (call-with-semaphore (socket-sema sock)
    (lambda ()
      (define ptr (socket-ptr* who sock))
      (define msg (socket-msg sock))
      (define (recvframe n)
        (zmq_msg_init msg)
        (let recvloop ()
          (let ([s (zmq_msg_recv msg ptr '(ZMQ_DONTWAIT))])
            (cond [(>= s 0)
                   (define size (zmq_msg_size msg))
                   (define frame (make-bytes size))
                   (memcpy frame (zmq_msg_data msg) size)
                   (define more? (zmq_msg_more msg))
                   (zmq_msg_close msg)
                   (values frame more?)]
                  [(or (= (saved-errno) EAGAIN)
                       (= (saved-errno) EINTR))
                   (*wait ptr ZMQ_POLLIN)
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

(define (zmq-recv sock #:who [who 'zmq-recv])
  (define frames (zmq-recv* sock #:who who))
  (cond [(and (pair? frames) (null? (cdr frames)))
         (car frames)]
        [else
         (error who "received multi-frame message\n  frames: ~s" (length frames))]))

(define (zmq-recv-string sock)
  (define msg (zmq-recv sock #:who 'zmq-recv-string))
  (bytes->string/utf-8 msg))
