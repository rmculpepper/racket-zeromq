#lang racket/base
(require ffi/unsafe
         ffi/unsafe/atomic
         ffi/unsafe/alloc
         ffi/unsafe/define)
(provide (protect-out (all-defined-out)))

(define RETRY-COUNT 5)

(define EAGAIN (lookup-errno 'EAGAIN))
(define EINTR (lookup-errno 'EINTR))
(define EINVAL 22) ;; FIXME

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
  (ffi-lib "libzmq" '(#f "5") #:fail (lambda () #f)) ;; FIXME: support v4?
  #:default-make-fail make-not-available)

(define-syntax-rule (_fun* part ...) (_fun #:save-errno 'posix part ...))

;; ----------------------------------------
;; Types

(define-cpointer-type _zmq_ctx-pointer)
(define-cpointer-type _zmq_socket-pointer)
(define-cpointer-type _zmq_msg-pointer)

;; ----------------------------------------
;; Constants and Enumerations

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

(define option-table
  '#hasheq(;; r = can read, w = can write, x = don't allow client to write (unsafe)
           [affinity .        (- x uint64)]
           [backlog .         (r w int)]
           [conflate .        (- x int)]
           [curve_publickey . (r w bytes)]
           [curve_secretkey . (r w bytes)]
           [curve_server .    (r w int)]
           [curve_serverkey . (r w bytes)]
           [events .          (- - int)]
           [fd .              (- - int)]
           [identity .        (r w bytes)]
           [immediate .       (r w int)] ;; ??
           [ipv6 .            (r w int)]
           [last_endpoint .   (r - bytes0)]
           [linger .          (r w int)] ;; ??
           [maxmsgsize .      (r w int64)]
           [mechanism .       (r - int)]
           [multicast_hops .  (r - int)]
           [plain_password .  (r w bytes0)]
           [plain_server .    (r w int)]
           [plain_username .  (r w bytes0)]
           [probe_router .    (- x int)]
           [rate .            (r w int)]
           [rcvbuf .          (r w int)]
           [rcvhwm .          (r w int)]
           [rcvmore .         (r - int)]
           [rcvtimeo .        (r w int)]
           [reconnect_ivl .   (r w int)]
           [reconnect_ivl_max . (r w int)]
           [recovery_ivl .    (r w int)]
           [req_correlate .   (- w int)]
           [req_relaxed .     (- w int)]
           [router_mandatory . (- w int)]
           [router_raw .      (- x int)]
           [sndbuf .          (r w int)]
           [sndhwm .          (r w int)]
           [sndtimeo .        (r w int)]
           [subscribe .       (- x bytes)]
           [tcp_accept_filter .   (- x bytes)]
           [tcp_keepalive .       (r w int)]
           [tcp_keepalive_cnt .   (r w int)]
           [tcp_keepalive_idle .  (r w int)]
           [tcp_keepalive_intvl . (r w int)]
           [type .            (r - int)]
           [unsubscribe .     (- x bytes)]
           [xpub_verbose .    (r w int)]
           [zap_domain .      (r w bytes0)]))

(define ZMQ_POLLIN  1)
(define ZMQ_POLLOUT 2)

(define (socket-option-type who opt)
  (cond [(hash-ref option-table opt #f) => caddr]
        [else (error who "unknown option\n  option: ~e" opt)]))
(define (socket-option-read? opt)  (memq 'r (hash-ref option-table opt '())))
(define (socket-option-write? opt) (memq 'w (hash-ref option-table opt '())))

(define ZMQ-MSG-SIZE 64)

(define _zmq_sendrecv_flags
  (_bitmask '(
              ZMQ_DONTWAIT = 1
              ZMQ_SNDMORE  = 2
              )
            _int))

;; ----------------------------------------
;; Misc

(define-zmq zmq_version
  (_fun (major : (_ptr o _int))
        (minor : (_ptr o _int))
        (patch : (_ptr o _int))
        -> _void
        -> (list major minor patch)))

(define-zmq zmq_strerror
  (_fun _int -> _string))

;; ----------------------------------------
;; Contexts

(define-zmq zmq_ctx_new
  (_fun* -> _zmq_ctx-pointer/null))

(define-zmq zmq_ctx_destroy
  (_fun* _zmq_ctx-pointer -> _int))

;; ----------------------------------------
;; Sockets

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

;; ----------------------------------------
;; Socket Options

(define (_getsockopt/type _T)
  (_fun* #:retry (retry [count 0])
         _zmq_socket-pointer
         _zmq_socket_option
         (value : (_ptr o _T))
         (len   : (_ptr io _size) = (ctype-sizeof _T))
         -> (status : _int)
         -> (cond [(zero? status) value]
                  [(and (= (saved-errno) EINTR) (< count RETRY-COUNT))
                   (retry (add1 count))]
                  [else #f])))

(define-zmq zmq_getsockopt/int    (_getsockopt/type _int)    #:c-id zmq_getsockopt)
(define-zmq zmq_getsockopt/int64  (_getsockopt/type _int64)  #:c-id zmq_getsockopt)
(define-zmq zmq_getsockopt/uint64 (_getsockopt/type _uint64) #:c-id zmq_getsockopt)

(define-zmq zmq_getsockopt/bytes
  (_fun* #:retry (retry [buflen 256] [first-try? #t])
         (sock opt [dlen 0]) ::
         (sock : _zmq_socket-pointer)
         (opt : _zmq_socket_option)
         (buf : _bytes = (make-bytes buflen))
         (len : (_ptr io _size) = buflen)
         -> (status : _int)
         -> (cond [(zero? status) (subbytes buf 0 (max 0 (+ len dlen)))]
                  [(and (= (saved-errno) EINVAL) first-try?)
                   (retry len #f)]
                  [(= (saved-errno) EINTR)
                   (retry buflen first-try?)]
                  [else #f]))
  #:c-id zmq_getsockopt)

(define (_setsockopt/type _T)
  (_fun* _zmq_socket-pointer
         _zmq_socket_option
         (_ptr i _T)
         (_size = (ctype-sizeof _T))
         -> _int))

(define-zmq zmq_setsockopt/int    (_setsockopt/type _int)    #:c-id zmq_setsockopt)
(define-zmq zmq_setsockopt/int64  (_setsockopt/type _int64)  #:c-id zmq_setsockopt)
(define-zmq zmq_setsockopt/uint64 (_setsockopt/type _uint64) #:c-id zmq_setsockopt)

(define-zmq zmq_setsockopt/bytes
  (_fun* _zmq_socket-pointer
         _zmq_socket_option
         (buf : _bytes)
         (_size = (bytes-length buf))
         -> _int)
  #:c-id zmq_setsockopt)

;; ----------------------------------------
;; Messages

(define-zmq zmq_msg_close
  (_fun* _zmq_msg-pointer -> _int)
  #:wrap (deallocator))

(define-zmq zmq_msg_init
  (_fun (m : _zmq_msg-pointer) -> _int -> m)
  #:wrap (allocator zmq_msg_close))

(define (new-zmq_msg)
  (define msg (cast (malloc ZMQ-MSG-SIZE 'atomic-interior) _pointer _zmq_msg-pointer))
  (zmq_msg_init msg)
  msg)

(define-zmq zmq_msg_data
  (_fun _zmq_msg-pointer -> _pointer))

(define-zmq zmq_msg_size
  (_fun _zmq_msg-pointer -> _size))

(define-zmq zmq_msg_more
  (_fun* _zmq_msg-pointer -> _bool))

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