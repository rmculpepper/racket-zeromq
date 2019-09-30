#lang racket/base
(require (for-syntax racket/base syntax/parse syntax/transformer)
         racket/contract/base
         racket/match
         racket/struct
         (except-in ffi/unsafe ->)
         ffi/unsafe/atomic
         ffi/unsafe/custodian
         ffi/unsafe/schedule
         ffi/unsafe/port
         "private/ffi.rkt"
         "private/mutex.rkt"
         "private/addr.rkt")
(provide zmq-socket?
         zmq-message?
         zmq-message/single-frame?
         zmq-available?
         zmq-version
         (rename-out [zmq-message* zmq-message])
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
          [zmq-closed-evt
           (-> zmq-socket? evt?)]
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
           (->* [zmq-socket?] [] #:rest (listof subscription/c) void?)]
          [zmq-send
           (->* [zmq-socket? msg-frame/c] [] #:rest (listof msg-frame/c) void?)]
          [zmq-send*
           (-> zmq-socket? (non-empty-listof msg-frame/c) void?)]
          [zmq-recv
           (-> zmq-socket? bytes?)]
          [zmq-recv-string
           (-> zmq-socket? string?)]
          [zmq-recv*
           (-> zmq-socket? (listof bytes?))]
          [zmq-message-frames
           (-> zmq-message? (listof bytes?))]
          [zmq-message-frame
           (-> zmq-message/single-frame? bytes?)]
          [zmq-recv-message
           (-> zmq-socket? zmq-message?)]
          [zmq-send-message
           (-> zmq-socket? zmq-message? void?)]
          [zmq-proxy
           (->* [zmq-socket? zmq-socket?]
                [#:capture (-> zmq-socket? zmq-message? any)
                 #:other-evt evt?]
                any)]))

(define socket-type/c
  (or/c 'pair 'pub 'sub 'req 'rep 'dealer 'router 'pull 'push 'xpub 'xsub 'stream))
(define bind-addr/c string?)
(define connect-addr/c string?)
(define subscription/c (or/c bytes? string?))
(define msg-frame/c (or/c bytes? string?))

;; Convention: procedures starting with "-" must be called in atomic mode.

(define DEFAULT-LINGER 100)

(define-logger zmq)

(define (zmq-available?) (and zmq-lib #t))
(define (zmq-version) (zmq_version))

;; ============================================================
;; Context

;; There is one implicit Instance (containing a zmq_ctx and a
;; zmq_poller) created on demand, only finalized when the namespace
;; and all created sockets go away.
(struct inst
  (ctx                  ;; _zmq_ctx-pointer
   poller               ;; _zmq_poller-pointer or #f if not supported
   sockptr=>events      ;; Hasheq[_zmq_socket-pointer => Nat]
   [wakeups #:mutable]  ;; Boolean -- #t if last poller callback was given wakeups
   ))

(define the-inst #f)

(define (-get-inst)
  (unless the-inst
    (log-zmq-debug "creating zmq_ctx")
    (define ctx (zmq_ctx_new))
    (log-zmq-debug "creating zmq_pollers")
    (define poller (and poller-available? (zmq_poller_new)))
    (register-finalizer ctx
                        (lambda (ctx)
                          (log-zmq-debug "destroying zmq_ctx")
                          (zmq_ctx_destroy ctx)))
    (register-finalizer poller
                        (lambda (poller)
                          (log-zmq-debug "destroying zmq_poller")
                          (zmq_poller_destroy poller)))
    (set! the-inst (inst ctx poller (make-hasheq) #f)))
  the-inst)

;; -get-ctx : -> Context
(define (-get-ctx) (inst-ctx (-get-inst)))

;; -inst-remove-sockptr : Inst _zmq_socket-pointer -> Void
(define (-inst-remove-sockptr in ptr)
  (match-define (inst _ poller sockptr=>events _) in)
  (when (hash-has-key? sockptr=>events ptr)
    (zmq_poller_remove poller ptr)
    (hash-remove! sockptr=>events ptr)))

;; -inst-check-wakeup : Inst Wakeups -> Void
;; If stored wakeups was #t and current is #f, then the previous
;; wakeup-gathering round is over, so clear the poller.
(define (-inst-check-wakeup in wakeups)
  ;; (log-zmq-debug "WAKEUPS: OLD = ~s, NEW = ~s" (inst-wakeups in) wakeups)
  (cond [(not in) (void)] ;; socket closed
        [(and (eq? (inst-wakeups in) #t) (eq? wakeups #f))
         ;; (log-zmq-debug "RESETTING WAKEUPS")
         (define poller (inst-poller in))
         (define sockptr=>events (inst-sockptr=>events in))
         (log-zmq-debug "new wakeup round, clearing poller (~s sockets)" (hash-count sockptr=>events))
         (for ([ptr (in-hash-keys sockptr=>events)])
           (zmq_poller_remove poller ptr))
         (hash-clear! sockptr=>events)
         (set-inst-wakeups! in #f)]
        [(and (eq? (inst-wakeups in) #f) wakeups)
         (set-inst-wakeups! in #t)]))

;; -inst-add-wakeup : Socket _zmq_socket-pointer Nat Wakeups -> Boolean
;; Returns #t if sleep should be canceled, #f otherwise.
(define (-inst-add-wakeup sock ptr event wakeups)
  (define in (socket-inst sock))
  (define (-wait-on-fd fd)
    (unsafe-poll-ctx-fd-wakeup wakeups fd 'read)
    (log-zmq-debug "wait; fd = ~s, socket = ~e" fd sock)
    #f)
  (cond [(threadsafe-socket? sock)
         (match-define (inst _ poller sockptr=>events _) (socket-inst sock))
         (cond [(hash-ref sockptr=>events ptr #f)
                => (lambda (old-event)
                     (let ([new-event (bitwise-ior old-event event)])
                       (zmq_poller_modify poller ptr new-event)
                       (hash-set! sockptr=>events ptr new-event)))]
               [else
                (zmq_poller_add poller ptr event)
                (hash-set! sockptr=>events ptr event)])
         (cond [(-poller-wait poller)
                (log-zmq-debug "poller returned immediately, socket = ~e" sock)
                #t]
               [else (-wait-on-fd (zmq_poller_fd poller))])]
        [else (-wait-on-fd (zmq_getsockopt/int ptr 'fd))]))

;; ============================================================
;; Socket

(struct socket
  (type                 ;; Symbol (_zmq_socket_type)
   [ptr #:mutable]      ;; _zmq_socket-pointer or #f -- #f means closed
   closed-sema          ;; Semaphore -- 0 initially, 1 if closed
   [ends #:mutable]     ;; (Listof Endpoint), where Endpoint = (cons (U 'bind 'connect) String)
   [inst #:mutable])    ;; Instance or #f -- #f only if closed
  ;; Like a channel, a zmq-socket acts as an evt. It is ready for sync when a
  ;; message can be read, and sync *reads and returns* the message itself.
  #:property prop:evt
  (lambda (self)
    (wrap-evt (recv-evt self) (lambda (r) (if (procedure? r) (r 'zmq-socket:evt) r))))
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

(struct standard-socket socket
  (wmutex       ;; Mutex -- protects sends, needed because of multi-frame sends
   ))

(struct threadsafe-socket socket ())

(define (zmq-socket? v) (socket? v))

;; ------------------------------------------------------------
;; Socket

;; zmq-socket : -> Socket
(define (zmq-socket type
                    #:identity [identity #f]
                    #:bind [bind-addrs null]
                    #:connect [connect-addrs null]
                    #:subscribe [subscriptions null]
                    #:join [groups null])
  (unless zmq-lib
    (error 'zmq-socket "could not find libzmq library\n  error: ~s"
           zmq-load-fail-reason))
  (when (and (threadsafe-socket-type? type) (not zmq_poller_fd))
    (error 'zmq-socket "socket type is not supported~a~a\n  type: ~e\n  version: ~a"
           ";\n cannot find `zmq_poller_fd` necessary for DRAFT socket types"
           ";\n libzmq must be version >= 4.3.2 and compiled with DRAFT API enabled"
           type (zmq-version-string)))
  (start-atomic)
  (define ptr (zmq_socket (-get-ctx) type))
  (unless ptr
    (end-atomic)
    (error 'zmq-socket "could not create socket\n  type: ~e~a" type (errno-lines)))
  (define sock
    (if (threadsafe-socket-type? type)
        (threadsafe-socket type ptr (make-semaphore 0) null the-inst)
        (standard-socket   type ptr (make-semaphore 0) null the-inst (make-mutex))))
  (register-finalizer-and-custodian-shutdown sock
    (lambda (sock) (-close 'zmq-socket-finalizer sock)))
  (end-atomic)
  ;; Set options, etc.
  (zmq-set-option sock 'linger DEFAULT-LINGER)
  (when identity (zmq-set-option sock 'identity identity))
  (apply zmq-subscribe sock (coerce->list subscriptions))
  (apply zmq-bind sock (coerce->list bind-addrs))
  (apply zmq-connect sock (coerce->list connect-addrs))
  (apply zmq-join sock (coerce->list groups))
  sock)

(define (zmq-close sock)
  (call-as-atomic
   (lambda ()
     (-close 'zmq-close sock))))

(define (-close who sock)
  (let ([ptr (socket-ptr sock)])
    (when ptr
      (log-zmq-debug "closing socket: ~e" sock)
      (set-socket-ptr! sock #f)
      (set-socket-ends! sock null)
      (when (standard-socket? sock)
        (unsafe-socket->semaphore (zmq_getsockopt/int ptr 'fd) 'remove))
      (-inst-remove-sockptr (socket-inst sock) ptr)
      (let ([s (zmq_close ptr)])
        (unless (zero? s)
          (log-zmq-error "error closing socket~a" (errno-lines))))
      (set-socket-inst! sock #f)
      (semaphore-post (socket-closed-sema sock)))))

(define (zmq-closed? sock) (not (socket-ptr sock)))

(define (zmq-list-endpoints sock mode)
  (ends-get (socket-ends sock) mode))

(define (ends-get ends type)
  (for/list ([c (in-list ends)] #:when (eq? (car c) type)) (cdr c)))

(define (zmq-closed-evt sock)
  (semaphore-peek-evt (socket-closed-sema sock)))

;; ----------------------------------------
;; Helpers

(define (call-with-socket-ptr who sock proc)
  (call-as-atomic
   (lambda ()
     (define ptr (socket-ptr sock))
     (unless ptr (error who "socket is closed\n  socket: ~e" sock))
     (proc ptr))))

(define (errno-lines [errno (saved-errno)])
  (format "\n  errno: ~s\n  error: ~.a" errno (zmq_strerror errno)))

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
          (error who "error getting socket option\n  socket: ~e\n  option: ~e~a"
                 sock option (errno-lines)))
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
          (error who "error setting socket option\n  socket: ~e\n  option: ~e\n  value: ~e~a"
                 sock option value (errno-lines)))))))

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
              (error who "error ~aing socket\n  socket: ~e\n  address: ~e~a"
                     mode sock addr (errno-lines)))
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
              (error who "error ~a socket\n  socket: ~e\n  address: ~e~a"
                     (case mode [(bind) "unbinding"] [(connect) "disconnecting"])
                     sock addr (errno-lines)))
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
              (error who "~a error\n  socket: ~e~a" mode sock (errno-lines)))))))))

(define (zmq-join sock . groups)
  (*join 'zmq-join 'join sock (map coerce->bytes groups)))
(define (zmq-leave sock . groups)
  (*join 'zmq-leave 'leave sock (map coerce->bytes groups)))

(define (*join who mode sock subs)
  ;; FIXME: check socket type?
  (when (pair? subs)
    (call-with-socket-ptr who sock
      (lambda (ptr)
        (for ([sub (in-list subs)])
          (let ([s (case mode [(join) (zmq_join ptr sub)] [(leave) (zmq_leave ptr sub)])])
            (unless (zero? s)
              (error who "~a error\n  socket: ~e~a" mode sock (errno-lines)))))))))

;; ----------------------------------------
;; Messages

;; A Message is (message (Listof Bytes) Meta)
;; A message struct represents a *whole* (possibly multi-frame) message along
;; with metadata such as routing-id and group for draft sockets (FIXME).
(struct message (frames meta)
  #:property prop:custom-write
  (make-constructor-style-printer
   (lambda (self) 'zmq-message)
   (lambda (self)
     (cons (message-frames self)
           (let ([meta (message-meta self)])
             (cond [(exact-integer? meta)
                    (list (unquoted-printing-string "#:routing-id") meta)]
                   [(bytes? meta)
                    (list (unquoted-printing-string "#:group") meta)]
                   [else null])))))
  #:transparent)

;; A Meta is one of
;; - #f     -- nothing
;; - Nat    -- a routing-id (CLIENT/SERVER only)
;; - Bytes  -- a group (RADIO/DISH only)
;; but may change in the future if libzmq changes.

(define (make-zmq-message frame/s #:routing-id [routing-id #f] #:group [group #f])
  (let ([frames (cond [(bytes? frame/s) (list frame/s)]
                      [(string? frame/s) (list (coerce->bytes frame/s))]
                      [(list? frame/s) (map coerce->bytes frame/s)])])
    (when (and routing-id group)
      (error 'zmq-message "cannot have both a routing-id and a group\n  routing-id: ~e\n  group: ~e"
             routing-id group))
    (message frames (or routing-id group))))

(define (zmq-message? v) (message? v))
(define (zmq-message-frames m)
  (message-frames m))
(define (zmq-message-frame m)
  (car (message-frames m)))
(define (zmq-message-routing-id m)
  (define meta (message-meta m))
  (and (exact-positive-integer? meta) meta))
(define (zmq-message-group m)
  (define meta (message-meta m))
  (and (bytes? meta) meta))

(define-module-boundary-contract zmq-message
  make-zmq-message
  (->* [(or/c (listof (or/c string? bytes?)) string? bytes?)]
       [#:routing-id (or/c #f exact-positive-integer?)
        #:group (or/c #f bytes?)]
       zmq-message?))

(define-match-expander zmq-message*
  (syntax-parser
    [(_ frames-pat:expr
        (~alt (~optional (~seq #:routing-id routing-id-pat:expr))
              (~optional (~seq #:group group-pat:expr)))
        ...)
     #'(? zmq-message?
          (app zmq-message-frames frames-pat)
          (~? (app zmq-message-routing-id routing-id-pat))
          (~? (app zmq-message-group group-pat)))])
  (set!-transformer-procedure
   (make-variable-like-transformer #'zmq-message)))

(define (zmq-message/single-frame? m)
  (match m [(message (list _) _) #t] [_ #f]))

;; ----------------------------------------
;; Send

;; A MsgPart is (U String Bytes)

;; zmq-send : Socket MsgPart ... -> Void
(define (zmq-send sock part1 . parts)
  (zmq-send* sock (cons part1 parts) #:who 'zmq-send))

(define (zmq-send* sock parts #:who [who 'zmq-send*])
  (define frames (map coerce->bytes parts))
  (zmq-send-message sock (message frames #f) #:who who))

(define (zmq-send-message sock m #:who [who 'zmq-send-message])
  (define (dead-error) (error who "socket is permanently locked for writes\n  socket: ~e" sock))
  (cond [(standard-socket? sock)
         (call-with-mutex (standard-socket-wmutex sock)
           (lambda () (send-frames who sock 0 (message-frames m) (message-meta m)))
           #:on-dead dead-error)]
        [(zmq-message/single-frame? m)
         (send-frames who sock 0 (message-frames m) (message-meta m))]
        [else
         (error who "socket does not support multi-frame messages\n  socket: ~e\n  message: ~e"
                sock m)]))

(define (send-frames who sock n frames meta)
  (define ((again-k n frames))
    (sync (send-ready-evt sock))
    (send-frames who sock n frames meta))
  ((call-with-socket-ptr who sock
     (lambda (ptr) (-send-frames-k who sock ptr n frames meta again-k)))))

(define (-send-frames-k who sock ptr n frames meta again-k)
  (define msg (new-zmq_msg))
  (let -loop ([n n] [frames frames]) ;; PRE: msg is uninitialized
    (define last? (null? (cdr frames)))
    (-init-send-msg msg (car frames) meta)
    (define s (zmq_msg_send msg ptr (if last? '(ZMQ_DONTWAIT) '(ZMQ_DONTWAIT ZMQ_SNDMORE))))
    (cond [(>= s 0) ;; successful send uninitializes msg
           (if (pair? (cdr frames))
               (-loop (add1 n) (cdr frames))
               (lambda () (void)))]
          [(= (saved-errno) EINTR)
           (zmq_msg_close msg)
           (-loop n frames)]
          [(= (saved-errno) EAGAIN)
           (zmq_msg_close msg)
           (again-k n frames)]
          [else
           (zmq_msg_close msg)
           (make-send-error who sock n (+ n (length frames)) (saved-errno))])))

(define ((make-send-error who sock n len errno))
  (error who "error sending message\n  socket: ~e\n  frame: ~s of ~s~a"
         sock (add1 n) len (errno-lines errno)))

;; send-ready-evt is an internal helper evt whose sync result is 'ready
(struct send-ready-evt (sock)
  #:property prop:evt
  (unsafe-poller
   (lambda (self wakeups)
     (define sock (send-ready-evt-sock self))
     (define ptr (socket-ptr sock))
     (define (ready) (values '(ready) #f))
     (define (not-ready) (values #f self))
     (-inst-check-wakeup (socket-inst sock) wakeups)
     (cond [(not ptr) (ready)] ;; ok, send-frames will report socket closed error
           [(-ready? ptr ZMQ_POLLOUT) (ready)]
           [wakeups (-wait/wakeups self sock ptr ZMQ_POLLOUT wakeups)]
           [else (not-ready)]))))

(define (-wait/wakeups self sock ptr event wakeups)
  (define (cancel-sleep) (values '(zmq:ask-again) #f))
  (define (not-ready) (values #f self))
  (if (-inst-add-wakeup sock ptr event wakeups) (cancel-sleep) (not-ready)))

(define (-ready? ptr event)
  (positive? (bitwise-and (zmq_getsockopt/int ptr 'events) event)))

(define (-init-send-msg msg frame meta)
  ;; PRE: msg is uninitialized
  (zmq_msg_init_size msg (bytes-length frame))
  (memcpy (zmq_msg_data msg) frame (bytes-length frame))
  (cond [(exact-integer? meta)
         (zmq_msg_set_routing_id msg meta)]
        [(bytes? meta)
         (zmq_msg_set_group msg meta)]
        [else (void)])
  (void))

;; ----------------------------------------
;; Atomic send evt

;; Restricted to the following combinations:
;; - the socket type must accept only single-frame messages (and thus not have write mutex)
;;   (FIXME: could restrict sockets at Racket level to single frames)
;; - the message must have a single frame
(define (zmq-send-evt sock m)
  (when (standard-socket? sock)
    (error 'zmq-send-evt "socket allows multi-frame messages\n  socket: ~e" sock))
  (match-define (message (list frame) meta) m)
  (wrap-evt (atomic-send-evt sock frame meta) (lambda (r) (begin (r) (void)))))

(struct atomic-send-evt (sock frame meta) ;; <: (evt-of (-> any))
  #:property prop:evt
  (unsafe-poller
   (lambda (self wakeups)
     (match-define (atomic-send-evt sock frame meta) self)
     (define ptr (socket-ptr sock))
     (define (ready v) (values (list v) #f))
     (define (cancel-sleep) (ready void))
     (define (not-ready) (values #f self))
     (-inst-check-wakeup (socket-inst sock) wakeups)
     (cond [(not ptr) (not-ready)]
           [(-ready? ptr ZMQ_POLLOUT)
            (cond [wakeups (cancel-sleep)]
                  [(-try-atomic-send sock ptr frame meta) (ready void)]
                  [else (not-ready)])]
           [wakeups (-wait/wakeups self sock ptr ZMQ_POLLOUT wakeups)]
           [else (not-ready)]))))

(define (-try-atomic-send sock ptr frame meta)
  (-send-frames-k 'zmq-send-evt sock ptr 0 (list frame) meta (lambda (n frames) #f)))

;; ----------------------------------------
;; Recv

(define (zmq-recv sock #:who [who 'zmq-recv])
  (define frames (zmq-recv* sock #:who who))
  (cond [(and (pair? frames) (null? (cdr frames)))
         (car frames)]
        [else (error who "received multi-frame message\n  socket: ~e\n  frames: ~s"
                     sock (length frames))]))

(define (zmq-recv-string sock)
  (define msg (zmq-recv sock #:who 'zmq-recv-string))
  (bytes->string/utf-8 msg))

(define (zmq-recv* sock #:who [who 'zmq-recv*])
  (zmq-message-frames (zmq-recv-message sock #:who who)))

#|
;; On Racket 7.4 and earlier, this version of zmq-recv-message causes busy
;; polling (100% cpu usage) when multiple threads block on sockets; see
;; racket/racket#2833. The replacement below partly mitigates the issue, but it
;; doesn't help if the program syncs directly on the sockets.
(define (zmq-recv-message sock #:who who)
  (define r
    (or (call-with-socket-ptr who sock (lambda (ptr) (-try-recv sock ptr)))
        (sync (recv-evt sock))))
  (if (procedure? r) (r who) r))
|#

(define (zmq-recv-message sock #:who [who 'zmq-recv-message])
  (define (do-recv who)
    (call-with-socket-ptr who sock
      (lambda (ptr)
        (or (-try-recv sock ptr)
            (if (threadsafe-socket? sock)
                (lambda (who)
                  (sync (recv-evt sock)))
                (lambda (who)
                  (sync (unsafe-socket->semaphore (zmq_getsockopt/int ptr 'fd) 'read))
                  do-recv))))))
  (let loop ([r (do-recv who)]) (if (procedure? r) (loop (r who)) r)))

;; recv-evt is an internal helper evt whose sync result is either a zmq-message
;; or a procedure to be called to report an error.
(struct recv-evt (sock)
  #:property prop:evt
  (unsafe-poller
   (lambda (self wakeups)
     (define sock (recv-evt-sock self))
     (define ptr (socket-ptr sock))
     (define (cancel-sleep) (values '(zeromq:ask-me-again) #f))
     (define (not-ready) (values #f self))
     (-inst-check-wakeup (socket-inst sock) wakeups)
     (cond [(not ptr) (not-ready)]
           [(-ready? ptr ZMQ_POLLIN)
            (cond [wakeups (cancel-sleep)]
                  [(-try-recv sock ptr)
                   => (lambda (r) (values (list r) #f))]
                  [else (not-ready)])]
           [wakeups (-wait/wakeups self sock ptr ZMQ_POLLIN wakeups)]
           [else (not-ready)]))))

;; -try-recv : Socket _socket-pointer -> (U #f Message (Symbol -> (error)))
(define (-try-recv sock ptr)
  (define msg (new-zmq_msg))
  (zmq_msg_init msg)
  (define (-loop1)
    (define s (zmq_msg_recv msg ptr '(ZMQ_DONTWAIT)))
    (cond [(>= s 0)
           (define meta (-get-msg-meta msg))
           (-get-frames 1 meta null)]
          [(= (saved-errno) EINTR) (-loop1)]
          [(= (saved-errno) EAGAIN) #f]
          [else (make-recv-error sock 1 (saved-errno))]))
  (define (-get-frames n meta rframes)
    (let ([rframes (cons (-get-msg-frame msg) rframes)])
      (cond [(zmq_msg_more msg)
             (-get-more-frames (add1 n) meta rframes)]
            [else (message (reverse rframes) meta)])))
  (define (-get-more-frames n meta rframes)
    (define s (zmq_msg_recv msg ptr '(ZMQ_DONTWAIT)))
    (cond [(>= s 0) (-get-frames n meta rframes)]
          [(= (saved-errno) EINTR) (-get-more-frames n meta rframes)]
          [(= (saved-errno) EAGAIN) ;; this is not supposed to be possible
           (lambda (who)
             (error who "internal error: got EAGAIN on frame ~s\n  socket: ~e" (add1 n) sock))]
          [else (make-recv-error sock n (saved-errno))]))
  (begin0 (-loop1)
    (zmq_msg_close msg)))

(define ((make-recv-error sock n errno) who)
  (error who "error receiving frame\n  socket: ~e\n  frame: ~s~a"
         sock n (errno-lines errno)))

(define (-get-msg-frame msg)
  (define size (zmq_msg_size msg))
  (define frame (make-bytes size))
  (memcpy frame (zmq_msg_data msg) size)
  frame)

(define (-get-msg-meta msg)
  (define routing-id (zmq_msg_routing_id msg))
  (define group (zmq_msg_group msg))
  (cond [(not (zero? routing-id)) routing-id]
        [group group]
        [else #f]))

;; ============================================================
;; Proxy

(define (zmq-proxy sock1 sock2
                   #:capture [capture #f]
                   #:other-evt [other-evt never-evt])
  (define sock1-closed-evt (wrap-evt (zmq-closed-evt sock1) void))
  (define sock2-closed-evt (wrap-evt (zmq-closed-evt sock2) void))
  (let loop ()
    (define ((forward from-sock to-sock) m)
      (when capture (capture from-sock m))
      (zmq-send-message to-sock m)
      (loop))
    (sync (handle-evt sock1 (forward sock1 sock2))
          (handle-evt sock2 (forward sock2 sock1))
          sock1-closed-evt
          sock2-closed-evt
          other-evt)))

;; ============================================================

;; Don't require this directly; use zeromq/unsafe instead.
(module* private-unsafe #f
  (provide (protect-out zmq-unsafe-connect zmq-unsafe-bind) bind-addr/c connect-addr/c)
  (define (zmq-unsafe-connect sock . addrs)
    (bind/connect 'zmq-unsafe-connect sock addrs 'connect #f))
  (define (zmq-unsafe-bind sock . addrs)
    (bind/connect 'zmq-unsafe-bind sock addrs 'bind #f)))

;; ============================================================

;; Don't require this; it exists only for testing.
(module* private-logger #f
  (provide zmq-logger))

;; ============================================================

;; WARNING: The following module is for testing support for the libzmq DRAFT
;; socket types and APIs. It *will* disappear in the future without notice.
(module* unstable-draft-4.3.2 #f
  ;; FIXME: contracts
  (provide
   zmq-draft-available?
   (contract-out
    [zmq-draft-socket
     (->* [draft-socket-type/c]
          [#:identity (or/c bytes? #f)
           #:bind (or/c bind-addr/c (listof bind-addr/c))
           #:connect (or/c connect-addr/c (listof connect-addr/c))
           #:join (or/c subscription/c (listof subscription/c))]
          zmq-socket?)]
    [zmq-send-evt
     (-> zmq-socket? zmq-message/single-frame? evt?)]
    [zmq-join
     (-> zmq-socket? bytes? void?)]
    [zmq-leave
     (-> zmq-socket? bytes? void?)]
    [zmq-message-routing-id
     (-> zmq-message? (or/c #f exact-positive-integer?))]
    [zmq-message-group
     (-> zmq-message? (or/c #f bytes?))]))

  (define zmq-draft-available? poller-available?)
  (define zmq-draft-socket zmq-socket) ;; this module's contract allows #:join
  (define draft-socket-type/c (or/c 'client 'server 'radio 'dish 'scatter 'gather)))
