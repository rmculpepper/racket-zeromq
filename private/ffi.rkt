#lang racket/base
(require ffi/unsafe
         ffi/unsafe/atomic
         ffi/unsafe/alloc
         ffi/unsafe/define)
(provide (protect-out (all-defined-out)))

(define EAGAIN (lookup-errno 'EAGAIN))
(define EINTR (lookup-errno 'EINTR))
(define EINVAL 22) ;; FIXME


(define-syntax-rule (_fun* part ...) (_fun #:save-errno 'posix part ...))


;; ========================================
;; Racket constants and functions

(define MZFD_CREATE_READ 1)
(define MZFD_CREATE_WRITE 2)
(define MZFD_REMOVE 5)

(define-ffi-definer define-racket #f)

(define-racket scheme_fd_to_semaphore
  (_fun _intptr _int _bool -> _racket))

;; ========================================
;; ZeroMQ constants and functions

(define-ffi-definer define-zmq
  (ffi-lib "libzmq" '("3" #f) #:fail (lambda () #f)) ;; FIXME: support v4?
  #:default-make-fail make-not-available)

(define _zmq_socket_type
  (_enum '(pair = 0
           pub  = 1
           sub  = 2
           req  = 3
           rep  = 4
           dealer = 5
           router = 6
           pull = 7
           push = 8
           xpub = 9
           xsub = 10
           stream = 11)
         _int))

(define-cpointer-type _zmq_ctx-pointer)
(define-cpointer-type _zmq_socket-pointer)

(define-zmq zmq_version
  (_fun (major : (_ptr o _int))
        (minor : (_ptr o _int))
        (patch : (_ptr o _int))
        -> _void
        -> (list major minor patch)))

;; ----

(define-zmq zmq_ctx_new
  (_fun* -> _zmq_ctx-pointer/null))

(define-zmq zmq_ctx_destroy
  (_fun* _zmq_ctx-pointer -> _int))

;; ----

(define-zmq zmq_socket
  (_fun* _zmq_ctx-pointer _zmq_socket_type -> _zmq_socket-pointer/null))

(define-zmq zmq_connect
  (_fun* _zmq_socket-pointer _string -> _int))

(define-zmq zmq_disconnect
  (_fun* _zmq_socket-pointer _string -> _int))

(define-zmq zmq_bind
  (_fun* _zmq_socket-pointer _string -> _int))

(define-zmq zmq_unbind
  (_fun* _zmq_socket-pointer _string -> _int))

(define-zmq zmq_close
  (_fun* _zmq_socket-pointer -> _int))

(define _zmq_socket_option
  (_enum '(
           affinity = 4
           identity = 5
           subscribe = 6
           unsubscribe = 7
           rate = 8
           recovery_ivl = 9
           sndbuf = 11
           rcvbuf = 12
           rcvmore = 13
           fd = 14
           events = 15
           type = 16
           linger = 17
           reconnect_ivl = 18
           backlog = 19
           reconnect_ivl_max = 21
           maxmsgsize = 22
           sndhwm = 23
           rcvhwm = 24
           multicast_hops = 25
           rcvtimeo = 27
           sndtimeo = 28
           last_endpoint = 32
           router_mandatory = 33
           tcp_keepalive = 34
           tcp_keepalive_cnt = 35
           tcp_keepalive_idle = 36
           tcp_keepalive_intvl = 37
           tcp_accept_filter = 38
           immediate = 39
           xpub_verbose = 40
           router_raw = 41
           ipv6 = 42
           mechanism = 43
           plain_server = 44
           plain_username = 45
           plain_password = 46
           curve_server = 47
           curve_publickey = 48
           curve_secretkey = 49
           curve_serverkey = 50
           probe_router = 51
           req_correlate = 52
           req_relaxed = 53
           conflate = 54
           zap_domain = 55
           )
         _int))

;; FIXME
(define integer-socket-options '(linger))
(define bytes-socket-options '(identity))

(define-zmq zmq_getsockopt/int
  (_fun* _zmq_socket-pointer
         _zmq_socket_option
         (value : (_ptr o _int))
         (len : (_ptr io _size) = (compiler-sizeof 'int))
         -> (status : _int)
         -> (and (zero? status) value))
  #:c-id zmq_getsockopt)

(define-zmq zmq_getsockopt/bytes
  (_fun* (sock opt buf) ::
         (sock : _zmq_socket-pointer)
         (opt : _zmq_socket_option)
         (buf : _bytes)
         (len : (_ptr io _size) = (bytes-length buf))
         -> (status : _int)
         -> (cons status len))
  #:c-id zmq_getsockopt)

;; zmq_getsockopt/bytes* : _zmq_socket-pointer _zmq_socket_option -> Bytes/#f
(define (zmq_getsockopt/bytes* sock opt)
  (let loop ([len 256] [first-try? #t])
    (define buf (make-bytes len 0))
    (define s+len (zmq_getsockopt/bytes sock opt buf))
    (cond [(zero? (cdr s+len))
           (if (= len (cdr s+len)) buf (subbytes buf (cdr s+len)))]
          [(and (= (saved-errno) EINVAL) first-try?)
           (loop (cdr s+len) #f)]
          [(= (saved-errno) EINTR)
           (loop len first-try?)]
          [else #f])))

(define-zmq zmq_setsockopt/int
  (_fun* _zmq_socket-pointer
         _zmq_socket_option
         (_ptr i _int)
         (_size = (compiler-sizeof 'int))
         -> _int)
  #:c-id zmq_setsockopt)

(define-zmq zmq_setsockopt/bytes
  (_fun* _zmq_socket-pointer
         _zmq_socket_option
         (buf : _bytes)
         (_size = (bytes-length buf))
         -> _int))

(define-zmq zmq_strerror
  (_fun _int -> _string))

;; ----

(define-cstruct _zmq_msg ((dummy (_array _byte 32)))
  #:malloc-mode 'atomic-interior)

(define-zmq zmq_msg_close
  (_fun* _zmq_msg-pointer -> _int))

(define-zmq zmq_msg_init
  (_fun* _zmq_msg-pointer -> _int))

(define new-zmq_msg ;; note: might be slow due to call-as-atomic
  ((allocator zmq_msg_close)
   (lambda ()
     (define msg (cast (malloc 'atomic-interior _zmq_msg) _pointer _zmq_msg-pointer))
     (define r (zmq_msg_init msg))
     (cond [(= r 0) msg]
           [else (error 'new-zmq_msg "message initialization failed\n  errno: ~s" (saved-errno))]))))

(define-zmq zmq_msg_data
  (_fun _zmq_msg-pointer -> _pointer))

(define-zmq zmq_msg_size
  (_fun _zmq_msg-pointer -> _size))

(define-zmq zmq_msg_more
  (_fun* _zmq_msg-pointer -> _bool))

(define _zmq_sendrecv_flags
  (_bitmask '(
              ZMQ_DONTWAIT = 1
              ZMQ_SNDMORE  = 2
              )
            _int))

(define-zmq zmq_send
  (_fun* _zmq_socket-pointer
         (buf : _bytes)
         (_size = (bytes-length buf))
         _zmq_sendrecv_flags
         -> _int))

(define-zmq zmq_recv
  (_fun* _zmq_socket-pointer
         (buf : _bytes)
         (_size = (bytes-length buf))
         _zmq_sendrecv_flags
         -> _int))

(define-zmq zmq_msg_recv
  (_fun* _zmq_msg-pointer _zmq_socket-pointer _zmq_sendrecv_flags
         -> _int))

(define-zmq zmq_msg_send
  (_fun* _zmq_msg-pointer _zmq_socket-pointer _zmq_sendrecv_flags
         -> _int))
