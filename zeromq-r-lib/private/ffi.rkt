#lang racket/base
(require ffi/unsafe
         ffi/unsafe/atomic
         ffi/unsafe/alloc
         ffi/unsafe/define)
(provide (protect-out (except-out (all-defined-out) zmq-load-fail-reason))
         zmq-load-fail-reason)

(define RETRY-COUNT 5)

(define EAGAIN (lookup-errno 'EAGAIN))
(define EINTR (lookup-errno 'EINTR))
(define EINVAL 22) ;; FIXME

;; ========================================
;; ZeroMQ constants and functions

(define zmq-load-fail-reason #f)

(define zmq-lib
  (with-handlers ([exn:fail?
                   (lambda (x)
                     (set! zmq-load-fail-reason (exn-message x))
                     #f)])
    (ffi-lib "libzmq" '("5" #f))))

(define-ffi-definer define-zmq zmq-lib
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
           stream = 11
           server = 12
           client = 13
           radio  = 14
           dish   = 15
           gather = 16
           scatter = 17
           dgram = 18
           )
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
           ;; support added in v1.1
           router_handover = 56
           tos = 57
           connect_routing_id = 61
           gssapi_server = 62
           gssapi_principal = 63
           gssapi_service_principal = 64
           gssapi_plaintext = 65
           handshake_ivl = 66
           socks_proxy = 68
           xpub_nodrop = 69
           blocky = 70
           xpub_manual = 71
           xpub_welcome_msg = 72
           stream_notify = 73
           invert_matching = 74
           heartbeat_ivl = 75
           heartbeat_ttl = 76
           heartbeat_timeout = 77
           xpub_verboser = 78
           connect_timeout = 79
           tcp_maxrt = 80
           thread_safe = 81
           multicast_maxtpdu = 84
           vmci_buffer_size = 85
           vmci_buffer_min_size = 86
           vmci_buffer_max_size = 87
           vmci_connect_timeout = 88
           use_fd = 89
           gssapi_principal_nametype = 90
           gssapi_service_principal_nametype = 91
           bindtodevice = 92
           )
         _int))

(define option-table
  '#hasheq(;; r = can read, w = can write, x = don't allow client to read/write (unsafe)
           [affinity .        (r x uint64)]
           [backlog .         (r w int)]
           [conflate .        (- x int)]
           [curve_publickey . (r w bytes)]
           [curve_secretkey . (r w bytes)]
           [curve_server .    (r w int)]
           [curve_serverkey . (r w bytes)]
           [events .          (x - int)]
           [fd .              (x - int)]
           [identity .        (r w bytes)]
           [immediate .       (r w int)] ;; ??
           [ipv6 .            (r w int)]
           [last_endpoint .   (r - bytes0)]
           [linger .          (r w int)] ;; ??
           [maxmsgsize .      (r w int64)]
           [mechanism .       (r - int)]
           [multicast_hops .  (r w int)]
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
           [zap_domain .      (r w bytes0)]
           ;; support added in v1.1:
           [router_handover   . (- w int)]
           [tos               . (r w int)]
           [connect_routing_id . (- w bytes)]
           [gssapi_server     . (r w int)]
           [gssapi_principal  . (r w bytes0)]
           [gssapi_service_principal . (r w bytes0)]
           [gssapi_plaintext  . (r w int)]
           [handshake_ivl     . (r w int)]
           [socks_proxy       . (r w bytes0)]
           [xpub_nodrop       . (- w int)]
           [xpub_manual       . (- w int)]
           [xpub_welcome_msg  . (- w bytes)]
           [stream_notify     . (- w int)]
           [invert_matching   . (r w int)]
           [heartbeat_ivl     . (- w int)]
           [heartbeat_ttl     . (- w int)]
           [heartbeat_timeout . (- w int)]
           [xpub_verboser     . (- w int)]
           [connect_timeout   . (r w int)]
           [tcp_maxrt         . (r w int)]
           [thread_safe       . (r - int)]
           [multicast_maxtpdu . (r w int)]
           [vmci_buffer_size  . (r w uint64)]
           [vmci_buffer_min_size . (r w uint64)]
           [vmci_buffer_max_size . (r w uint64)]
           [vmci_connect_timeout . (r w int)]
           [use_fd            . (x x int)]
           [gssapi_principal_nametype . (r w int)]
           [gssapi_service_principal_nametype . (r w int)]
           [bindtodevice      . (r w bytes)]
           ))

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
        -> (list major minor patch))
  #:fail (lambda () (lambda () #f)))

(define (zmq-version-string)
  (define v (zmq_version))
  (format "~a.~a.~a" (car v) (cadr v) (caddr v)))

(define-zmq zmq_strerror
  (_fun _int -> _string))

(define-zmq zmq_has
  (_fun _string/utf-8 -> _bool)
  #:fail (lambda () (lambda (s) #f)))

(define-zmq zmq_curve_keypair
  (_fun* (pubkey : _bytes = (make-bytes 41))
         (privkey : _bytes = (make-bytes 41))
         -> (s : _int) -> (and (zero? s) (list pubkey privkey)))
  #:fail (lambda () (lambda () #f)))

(define-zmq zmq_curve_public
  (_fun* (pubkey : _bytes = (make-bytes 41)) (privkey : _bytes)
         -> (s : _int) -> (and (zero? s) pubkey)))

(define-zmq zmq_z85_decode
  (_fun* (in) ::
         (out : _bytes = (let ([inlen (bytes-length in)])
                           (cond [(= (remainder inlen 5) 0)
                                  (make-bytes (* 4/5 (bytes-length in)))]
                                 [(and (= (remainder inlen 5) 1)
                                       (= (bytes-ref in (sub1 inlen)) 0))
                                  (make-bytes (* 4/5 (sub1 (bytes-length in))))]
                                 [else
                                  (error 'zmq_z85_decode "bad input: ~e" in)])))
         (in : _bytes)
         -> (s : _pointer) -> (and s out)))

(define-zmq zmq_z85_encode
  (_fun* (in) ::
         (out : _bytes = (make-bytes (add1 (ceiling (* 5/4 (bytes-length in))))))
         (in : _bytes)
         (inlen : _size = (bytes-length in))
         -> (s : _pointer) -> (and s out)))


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
  (_fun* _zmq_msg-pointer -> _int))

(define-zmq zmq_msg_init
  (_fun (m : _zmq_msg-pointer) -> _int -> m))

(define-zmq zmq_msg_init_size
  (_fun (m : _zmq_msg-pointer) _size -> _int))

(define (new-zmq_msg)
  (define p (malloc ZMQ-MSG-SIZE 'atomic-interior))
  (cpointer-push-tag! p zmq_msg-pointer-tag)
  p)

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

;; ============================================================
;; DRAFT API

(define draft-socket-types
  '(server client radio dish gather scatter dgram))
(define threadsafe-socket-types ;; ??
  '(server client radio dish gather scatter))

(define (threadsafe-socket-type? x)
  (and (memq x threadsafe-socket-types) #t))

(define (single-frame-socket-type? x)
  ;; true if the socket type allows only single-frame messages
  (threadsafe-socket-type? x))

(define-zmq zmq_msg_routing_id
  (_fun _zmq_msg-pointer -> _uint32)
  #:fail (lambda () (lambda (msg) 0)))
(define-zmq zmq_msg_set_routing_id
  (_fun _zmq_msg-pointer _uint32 -> _int)
  #:fail (lambda () void))

(define-zmq zmq_msg_group
  (_fun _zmq_msg-pointer -> _bytes/nul-terminated)
  #:fail (lambda () (lambda (msg) #f)))
(define-zmq zmq_msg_set_group
  (_fun _zmq_msg-pointer _bytes/nul-terminated -> _int)
  #:fail (lambda () void))

(define-zmq zmq_join
  (_fun* _zmq_socket-pointer _bytes/nul-terminated -> _int))
(define-zmq zmq_leave
  (_fun* _zmq_socket-pointer _bytes/nul-terminated -> _int))

;; ----------------------------------------
;; Poller

(define-cpointer-type _zmq_poller-pointer)

(define-zmq zmq_poller_new
  (_fun -> _zmq_poller-pointer)
  #:fail (lambda () #f))
(define-zmq zmq_poller_destroy
  (_fun (_ptr i _zmq_poller-pointer) -> _int))

(define-zmq zmq_poller_add
  (_fun _zmq_poller-pointer _zmq_socket-pointer (_pointer = #f) _short -> _int))
(define-zmq zmq_poller_modify
  (_fun _zmq_poller-pointer _zmq_socket-pointer _short -> _int))
(define-zmq zmq_poller_remove
  (_fun _zmq_poller-pointer _zmq_socket-pointer -> _int))

(define-zmq zmq_poller_fd
  (_fun _zmq_poller-pointer (fd : (_ptr o _int)) -> (s : _int) -> (and (zero? s) fd))
  #:fail (lambda () #f))

(define-cstruct _zmq_poller_event_t
  ([socket _zmq_socket-pointer/null]
   [fd _int]
   [user_data _pointer]
   [events _short])
  #:malloc-mode 'atomic-interior)

(define-zmq zmq_poller_wait
  (_fun _zmq_poller-pointer _zmq_poller_event_t-pointer _long -> _int))
(define-zmq zmq_poller_wait_all
  (_fun _zmq_poller-pointer _zmq_poller_event_t-pointer _int _long -> _int))

;; Calling zmq_poller_wait_all seems to make poller to scan signalers and quiet
;; its fd if there aren't any relevant events. Since we only do this before
;; sleeping, and even one event is enough to cancel the sleep, an array of only
;; one _zmq_poller_event_t is okay.
(define (-poller-wait poller)
  (define a (cast (malloc 'atomic-interior _zmq_poller_event_t)
                  _pointer _zmq_poller_event_t-pointer))
  (> (zmq_poller_wait_all poller a 1 0) 0))

(define poller-available? (and zmq_poller_new zmq_poller_fd #t))

;; ============================================================
;; Socket monitor

(define _zmq_socket_events
  (_bitmask '(
              connected       = #x0001
              connect_delayed = #x0002
              connect_retried = #x0004
              listening       = #x0008
              bind_failed     = #x0010
              accepted        = #x0020
              accept_failed   = #x0040
              closed          = #x0080
              close_failed    = #x0100
              disconnected    = #x0200
              monitor_stopped = #x0400
              all             = #xffff
              ;; Unspecified system errors during handshake. Event value is an errno.
              handshake_failed_no_detail = #x0800
              ;; Handshake complete successfully with successful authentication (if
              ;; enabled). Event value is unused.
              handshake_succeeded = #x1000
              ;; Protocol errors between ZMTP peers or between server and ZAP handler.
              ;; Event value is one of ZMQ_PROTOCOL_ERROR_*
              handshake_failed_protocol = #x2000
              ;; Failed authentication requests. Event value is the numeric ZAP status
              ;; code, i.e. 300, 400 or 500.
              handshake_failed_auth = #x4000
              )
            _int))

(define _zmq_protocol_error
  (_enum '(
           zmtp_unspecified                   = #x10000000
           zmtp_unexpected_command            = #x10000001
           zmtp_invalid_sequence              = #x10000002
           zmtp_key_exchange                  = #x10000003
           zmtp_malformed_command_unspecified = #x10000011
           zmtp_malformed_command_message     = #x10000012
           zmtp_malformed_command_hello       = #x10000013
           zmtp_malformed_command_initiate    = #x10000014
           zmtp_malformed_command_error       = #x10000015
           zmtp_malformed_command_ready       = #x10000016
           zmtp_malformed_command_welcome     = #x10000017
           zmtp_invalid_metadata              = #x10000018
           zmtp_cryptographic                 = #x11000001
           zmtp_mechanism_mismatch            = #x11000002
           zap_unspecified                    = #x20000000
           zap_malformed_reply                = #x20000001
           zap_bad_request_id                 = #x20000002
           zap_bad_version                    = #x20000003
           zap_invalid_status_code            = #x20000004
           zap_invalid_metadata               = #x20000005
           )
         _int))

(define (decode-socket-events se)
  (cast se _int _zmq_socket_events))

(define (decode-protocol-error pe)
  (cast pe _int _zmq_protocol_error))

(define-zmq zmq_socket_monitor
  (_fun* _zmq_socket-pointer _string _zmq_socket_events -> _int))
