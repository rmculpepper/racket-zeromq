#lang racket/base
(require racket/contract/base
         racket/struct
         (except-in ffi/unsafe ->)
         ffi/unsafe/atomic
         ffi/unsafe/custodian
         ffi/unsafe/port
         "private/ffi.rkt"
         "private/addr.rkt")
(provide zmq-socket?
         (contract-out
          [zmq-socket
           (->* [socket-type/c]
                [#:identity (or/c bytes? #f)
                 #:bind (or/c bind-addr/c (listof bind-addr/c))
                 #:connect (or/c connect-addr/c (listof connect-addr/c))
                 #:subscribe (or/c subscription/c (listof subscription/c))]
                zmq-socket?)]
          [zmq-close
           (-> zmq-socket? void?)]
          [zmq-closed?
           (-> zmq-socket? boolean?)]
          [zmq-list-endpoints
           (-> zmq-socket? (or/c 'bind 'connect) (listof string?))]
          [zmq-get-option
           (-> zmq-socket? symbol? any/c)]
          [zmq-set-option
           (-> zmq-socket? symbol? (or/c exact-integer? bytes?) void?)]
          [zmq-list-options
           (-> (or/c 'get 'set) (listof symbol?))]
          [zmq-connect
           (->* [zmq-socket?] [] #:rest (listof connect-addr/c) void?)]
          [zmq-bind
           (->* [zmq-socket?] [] #:rest (listof bind-addr/c) void?)]
          [zmq-disconnect
           (->* [zmq-socket?] [] #:rest (listof connect-addr/c) void?)]
          [zmq-unbind
           (->* [zmq-socket?] [] #:rest (listof bind-addr/c) void?)]
          [zmq-subscribe
           (->* [zmq-socket?] [] #:rest (listof subscription/c) void?)]
          [zmq-unsubscribe
           (->* [zmq-socket?] [] #:rest (listof bytes?) void?)]
          [zmq-send
           (->* [zmq-socket? msg-frame/c] [] #:rest (listof msg-frame/c) void?)]
          [zmq-send*
           (-> zmq-socket? (non-empty-listof msg-frame/c) void?)]
          [zmq-recv
           (-> zmq-socket? bytes?)]
          [zmq-recv-string
           (-> zmq-socket? string?)]
          [zmq-recv*
           (-> zmq-socket? (listof bytes?))]))

(define socket-type/c
  (or/c 'pair 'pub 'sub 'req 'rep 'dealer 'router 'pull 'push 'xpub 'xsub 'stream))
(define bind-addr/c string?)
(define connect-addr/c string?)
(define subscription/c (or/c bytes? string?))
(define msg-frame/c (or/c bytes? string?))

;; TODO:
;; - better integration with evt system
;;   - add timeout/evt to recv?
;;   - add maybe-recv-evt?

;; Convention: procedures starting with "-" must be called in atomic mode.

(define DEFAULT-LINGER 100)

(define-logger zmq)

;; ============================================================
;; Context

;; There is one implicit context created on demand, only finalized
;; when the namespace goes away.

(define the-ctx #f)

;; -get-ctx : -> Context
(define (-get-ctx)
  (unless the-ctx
    (log-zmq-debug "creating zmq_ctx")
    (define ctx (zmq_ctx_new))
    (register-finalizer ctx
      (lambda (ctx)
        (log-zmq-debug "destroying zmq_ctx")
        (zmq_ctx_destroy ctx)))
    (set! the-ctx ctx))
  the-ctx)

;; ============================================================
;; Socket

;; A Socket is (socket Symbol (U _zmq_socket-pointer #f) Semaphore Semaphore (Listof Endpoint))
;; A Endpoint is (cons 'bind String) | (cons 'connect String)
(struct socket (type [ptr #:mutable] rsema wsema [ends #:mutable])
  #:property prop:custom-write
  (make-constructor-style-printer
   (lambda (s) 'zmq-socket)
   (lambda (s)
     (define (pp:lit s) (unquoted-printing-string s))
     (define type (socket-type s))
     (define identity
       (call-as-atomic
        (lambda ()
          (cond [(socket-ptr s) => (lambda (ptr) (zmq_getsockopt/bytes ptr 'identity))]
                [else #f]))))
     (define binds (ends-get (socket-ends s) 'bind))
     (define connects (ends-get (socket-ends s) 'connect))
     (append (list type)
             (if (and identity (not (equal? identity #""))) (list (pp:lit "#:identity") identity) '())
             (if (pair? binds) (list (pp:lit "#:bind") binds) '())
             (if (pair? connects) (list (pp:lit "#:connect") connects) '())))))

(define (zmq-socket? v) (socket? v))

;; ------------------------------------------------------------
;; Socket

;; zmq-socket : -> Socket
(define (zmq-socket type
                    #:identity [identity #f]
                    #:bind [bind-addrs null]
                    #:connect [connect-addrs null]
                    #:subscribe [subscriptions null])
  (unless zmq-lib
    (error 'zmq-socket "could not find libzmq library\n  error: ~s"
           zmq-load-fail-reason))
  (start-atomic)
  (define ctx (-get-ctx))
  (define ptr (zmq_socket ctx type))
  (unless ptr
    (end-atomic)
    (error 'zmq-socket "could not create socket\n  type: ~e~a" type (errno-lines)))
  (define sock (socket type ptr (make-semaphore 1) (make-semaphore 1) null))
  (register-finalizer-and-custodian-shutdown sock
    (lambda (sock) (-close 'zmq-socket-finalizer sock)))
  (end-atomic)
  ;; Set options, etc.
  (zmq-set-option sock 'linger DEFAULT-LINGER)
  (when identity (zmq-set-option sock 'identity identity))
  (apply zmq-subscribe sock (coerce->list subscriptions))
  (apply zmq-bind sock (coerce->list bind-addrs))
  (apply zmq-connect sock (coerce->list connect-addrs))
  sock)

(define (zmq-close sock)
  (call-as-atomic
   (lambda ()
     (-close 'zmq-close sock))))

(define (-close who sock)
  (let ([ptr (socket-ptr sock)])
    (when ptr
      (log-zmq-debug "closing socket (~a)"
                     (cast (zmq_getsockopt/int ptr 'type) _int _zmq_socket_type))
      (set-socket-ptr! sock #f)
      (set-socket-ends! sock null)
      (define fd (zmq_getsockopt/int ptr 'fd))
      (fd->evt fd 'remove)
      (let ([s (zmq_close ptr)])
        (unless (zero? s)
          (log-zmq-error "error closing socket~a" (errno-lines)))))))

(define (fd->evt fd mode)
  ;; The fd *must* be interpreted as a socket on Windows and Mac OS.
  ;; On Linux it does not seem to matter.
  (unsafe-fd->evt fd mode #t))

(define (zmq-closed? sock) (not (socket-ptr sock)))

(define (zmq-list-endpoints sock mode)
  (ends-get (socket-ends sock) mode))

(define (ends-get ends type)
  (for/list ([c (in-list ends)] #:when (eq? (car c) type)) (cdr c)))

;; ----------------------------------------
;; Helpers

(define (call-with-socket-ptr who sock proc)
  (call-as-atomic
   (lambda ()
     (define ptr (socket-ptr sock))
     (unless ptr (error who "socket is closed"))
     (proc ptr))))

(define (errno-lines)
  (format "\n  errno: ~s\n  error: ~.a" (saved-errno) (zmq_strerror (saved-errno))))

(define (coerce->list x) (if (list? x) x (list x)))
(define (coerce->bytes x) (if (string? x) (string->bytes/utf-8 x) x))

;; ----------------------------------------
;; Options

(define (zmq-get-option sock option
                        #:who [who 'zmq-get-option])
  (define type (socket-option-type who option))
  (unless (socket-option-read? option)
    (error who "socket option is not readable\n  option: ~e" option))
  (call-with-socket-ptr who sock
    (lambda (ptr)
      (let ([v (case type
                 [(int)     (zmq_getsockopt/int ptr option)]
                 [(int64)   (zmq_getsockopt/int64 ptr option)]
                 [(uint64)  (zmq_getsockopt/uint64 ptr option)]
                 [(bytes)   (zmq_getsockopt/bytes ptr option)]
                 [(bytes0)  (zmq_getsockopt/bytes ptr option -1)])])
        (unless v
          (error who "error getting socket option\n  option: ~e~a"
                 option (errno-lines)))
        v))))

(define (zmq-set-option sock option value
                        #:who [who 'zmq-set-option])
  (define type (socket-option-type who option))
  (unless (socket-option-write? option)
    (error who "socket option is not writable\n  option: ~e" option))
  (define (check-value pred ctc)
    (unless (pred value)
      (error who "bad value for option\n  option: ~e\n  expected: ~a\n  given: ~e"
             option ctc value)))
  (case type
    [(int) (check-value exact-integer? "exact-integer?")]
    [(uint64) (check-value exact-nonnegative-integer? "exact-nonnegative-integer?")]
    [(bytes bytes0) (check-value bytes? "bytes?")])
  (call-with-socket-ptr who sock
    (lambda (ptr)
      (let ([s (case type
                 [(int)    (zmq_setsockopt/int ptr option value)]
                 [(int64)  (zmq_setsockopt/int64 ptr option value)]
                 [(uint64) (zmq_setsockopt/uint64 ptr option value)]
                 [(bytes bytes0) (zmq_setsockopt/bytes ptr option value)])])
        (unless (zero? s)
          (error who "error setting socket option\n  option: ~e\n  value: ~e~a"
                 option value (errno-lines)))))))

(define (zmq-list-options mode)
  (sort (for/list ([opt (in-hash-keys option-table)]
                   #:when (case mode [(get) (socket-option-read? opt)] [(set) (socket-option-write? opt)]))
          opt)
        symbol<?))

;; ----------------------------------------
;; Connect and Bind

(define (zmq-connect sock . addrs) (bind/connect 'zmq-connect sock addrs 'connect #t))
(define (zmq-bind sock . addrs) (bind/connect 'zmq-bind sock addrs 'bind #t))

(define (bind/connect who sock addrs0 mode check?)
  (when (pair? addrs0)
    (define addrs
      (if check?
          (for/list ([addr (in-list addrs0)]) (check-endp who addr mode))
          addrs0))
    (call-with-socket-ptr who sock
      (lambda (ptr)
        (for ([addr (in-list addrs)])
          (let ([s (case mode
                     [(bind) (zmq_bind ptr addr)]
                     [(connect) (zmq_connect ptr addr)])])
            (unless (zero? s)
              (error who "error ~aing socket\n  address: ~e~a" mode addr (errno-lines)))
            (-add-end! sock ptr mode addr)))))))

(define (zmq-disconnect sock . addrs) (unbind/disconnect 'zmq-disconnect sock addrs 'connect))
(define (zmq-unbind sock . addrs) (unbind/disconnect 'zmq-unbind sock addrs 'bind))

(define (unbind/disconnect who sock addrs mode)
  (when (pair? addrs)
    (call-with-socket-ptr who sock
      (lambda (ptr)
        (for ([addr (in-list addrs)])
          (let ([s (case mode
                     [(bind) (zmq_unbind ptr addr)]
                     [(connect) (zmq_disconnect ptr addr)])])
            (unless (zero? s)
              (error who "error ~a socket\n  address: ~e~a"
                     (case mode [(bind) "unbinding"] [(connect) "disconnecting"])
                     addr (errno-lines)))
            (-sub-end! sock ptr mode addr)))))))

(define (-add-end! sock ptr mode addr)
  (define addr* (if (regexp-match? #rx"^(tcp|ipc):" addr)
                    (bytes->string/utf-8 (zmq_getsockopt/bytes ptr 'last_endpoint -1))
                    addr))
  (set-socket-ends! sock (cons (cons mode addr*) (socket-ends sock))))

(define (-sub-end! sock ptr mode addr)
  (set-socket-ends! sock (remove (cons mode addr) (socket-ends sock))))

;; ----------------------------------------
;; Subscriptions

(define (zmq-subscribe sock . subs)
  (*subscribe 'zmq-subscribe 'subscribe sock (map coerce->bytes subs)))
(define (zmq-unsubscribe sock . subs)
  (*subscribe 'zmq-unsubscribe 'unsubscribe sock (map coerce->bytes subs)))

(define (*subscribe who mode sock subs)
  (when (pair? subs)
    (call-with-socket-ptr who sock
      (lambda (ptr)
        (for ([sub (in-list subs)])
          (let ([s (zmq_setsockopt/bytes ptr mode sub)])
            (unless (zero? s)
              (error who "~a error~a" mode (errno-lines)))))))))

;; ----------------------------------------
;; Send and Recv

;; A MsgPart is (U String Bytes)

;; FIXME: if thread is interrupted (break/kill) while sending a
;; message with multiple frames, a subsequent send will get confused
;; as more frames in first message. (Likewise for read.)

;; zmq-send : Socket MsgPart ... -> Void
(define (zmq-send sock part1 . parts)
  (zmq-send* sock (cons part1 parts) #:who 'zmq-send))

(define (zmq-send* sock parts #:who [who 'zmq-send*])
  (define frames (map coerce->bytes parts))
  (call-with-semaphore (socket-wsema sock)
    (lambda () (send-frames who sock 0 frames))))

(define (send-frames who sock n frames)
  ((call-with-socket-ptr who sock
     (lambda (ptr) (-send-frames-k who sock ptr n frames)))))

(define (-send-frames-k who sock ptr n frames)
  (define last? (null? (cdr frames)))
  (define s (zmq_send ptr (car frames) (if last? '(ZMQ_DONTWAIT) '(ZMQ_DONTWAIT ZMQ_SNDMORE))))
  (cond [(>= s 0)
         (if (pair? (cdr frames))
             (-send-frames-k who sock ptr (add1 n) (cdr frames))
             (lambda () (void)))]
        [(or (= (saved-errno) EAGAIN) (= (saved-errno) EINTR))
         (lambda ()
           (wait who sock ZMQ_POLLOUT)
           (send-frames who sock n frames))]
        [else
         (lambda ()
           (error who "error sending message\n  frame: ~s of ~s~a"
                  (add1 n) (+ n (length frames)) (errno-lines)))]))

(define (wait who sock event)
  (start-atomic)
  (define ptr (socket-ptr sock))
  (unless ptr
    (end-atomic)
    (error who "socket is closed"))
  (define events (zmq_getsockopt/int ptr 'events))
  (cond [(positive? (bitwise-and events event))
         (end-atomic)]
        [else
         (define fd (zmq_getsockopt/int ptr 'fd))
         (define fdsema (fd->evt fd 'read))
         (end-atomic)
         (log-zmq-debug "~s wait; fd = ~s, socket = ~e" who fd sock)
         (sync fdsema)
         (wait who sock event)]))

(define (zmq-recv sock #:who [who 'zmq-recv])
  (define frames (zmq-recv* sock #:who who))
  (cond [(and (pair? frames) (null? (cdr frames)))
         (car frames)]
        [else (error who "received multi-frame message\n  frames: ~s" (length frames))]))

(define (zmq-recv-string sock)
  (define msg (zmq-recv sock #:who 'zmq-recv-string))
  (bytes->string/utf-8 msg))

(define (zmq-recv* sock #:who [who 'zmq-recv*])
  (call-with-semaphore (socket-rsema sock)
    (lambda () (recv-frames who sock null))))

(define (recv-frames who sock rframes)
  ((call-with-socket-ptr who sock
     (lambda (ptr) (-recv-frames-k who sock ptr rframes)))))

(define (-recv-frames-k who sock ptr rframes)
  (define msg (new-zmq_msg))
  (zmq_msg_init msg)
  (define s (zmq_msg_recv msg ptr '(ZMQ_DONTWAIT)))
  (cond [(>= s 0)
         (define frame (-get-msg-frame msg))
         (define more? (zmq_msg_more msg))
         (zmq_msg_close msg)
         (cond [more?
                (-recv-frames-k who sock ptr (cons frame rframes))]
               [else (lambda () (reverse (cons frame rframes)))])]
        [(or (= (saved-errno) EAGAIN) (= (saved-errno) EINTR))
         (zmq_msg_close msg)
         (lambda ()
           (wait who sock ZMQ_POLLIN)
           (recv-frames who sock rframes))]
        [else
         (zmq_msg_close msg)
         (lambda ()
           (error who "error receiving message~a~a"
                  (let ([ct (length rframes)])
                    (if (zero? ct) "" (format "\n  frame: ~s" (add1 ct))))
                  (errno-lines)))]))

(define (-get-msg-frame msg)
  (define size (zmq_msg_size msg))
  (define frame (make-bytes size))
  (memcpy frame (zmq_msg_data msg) size)
  frame)

;; ============================================================

;; Don't require this directly; use zeromq/unsafe instead.
(module* private-unsafe #f
  (provide (protect-out zmq-unsafe-connect zmq-unsafe-bind) bind-addr/c connect-addr/c)
  (define (zmq-unsafe-connect sock . addrs)
    (bind/connect 'zmq-unsafe-connect sock addrs 'connect #f))
  (define (zmq-unsafe-bind sock . addrs)
    (bind/connect 'zmq-unsafe-bind sock addrs 'bind #f)))
