#lang racket/base
(require racket/match
         ffi/file)
(provide check-endp)

(define (security-guard-check-network* who host port mode)
  ;; Racket 6.10 requires host arg to be string instead of string/#f,
  ;; so just omit host=#f checks for now.
  (when host (security-guard-check-network who host port mode)))

;; ----

;; check-endp : Symbol String 'bind/'connect -> String
;; Parses, checks permissions, and returns normalized endpoint.
;; (Note: only icp (unix socket) endpoints need normalizing.)
(define (check-endp who endp mode)
  (define-values (transport addr) (split-endp endp))
  (case transport
    [(tcp) (case mode
             [(connect) (check-conn/tcp who endp addr) endp]
             [(bind)    (check-bind/tcp who endp addr) endp])]
    [(pgm epgm) (case mode
                  [(connect) (check-conn/pgm who endp transport addr) endp]
                  [else (bad-endp who endp mode)])]
    [(ipc) (check-*/ipc who endp mode addr)]
    [(inproc) endp]
    [(udp) (case mode
             [(connect) (check-conn/udp who endp addr) endp]
             [(bind)    (check-bind/udp who endp addr) endp])]
    [else (bad-endp who endp mode)]))

;; split-endp : String -> (values Symbol/#f String)
;; Splits endpoint into (normalized) transport and address.
(define (split-endp endp)
  (match endp
    [(regexp #rx"^([a-zA-Z]+)://(.*)$" (list _ transport addr))
     (values (string->symbol (string-downcase transport)) addr)]
    [_ (values #f endp)]))

;; check-{conn,bind}/tcp : Symbol String String -> Void
(define (check-conn/tcp who endp addr)
  (match addr
    [(regexp #rx"^(?:([-a-zA-Z0-9.]+|[*]):([0-9]+);)?([-a-zA-Z0-9.]+):([0-9]+)$"
             (list _ ifc port peer-name peer-port))
     (when ifc (check-net-bind who endp ifc port 'connect))
     (check-net-connect who endp peer-name peer-port)]
    [_ (bad-endp who endp 'connect)]))
(define (check-bind/tcp who endp addr)
  (match addr
    [(regexp #rx"^([-a-zA-Z0-9.]+|[*]):([0-9]+)$" (list _ ifc port))
     (check-net-bind who endp ifc port)]
    [_ (bad-endp who endp 'bind)]))

;; check-{conn,bind}/udp : Symbol String String -> Void
(define (check-conn/udp who endp addr)
  (match addr
    [(regexp #rx"^([-a-zA-Z0-9.]+):([0-9]+)$" (list _ name port))
     (check-net-connect who endp name port)]
    [_ (bad-endp who endp 'connect)]))
(define (check-bind/udp who endp addr)
  (match addr
    [(regexp #rx"^([-a-zA-Z0-9.]+|[*]):([0-9]+)$" (list _ name port))
     ;; FIXME: udp bind interface must be numeric IPv4 endp
     (check-net-bind who endp name port)]
    [_ (bad-endp who endp 'bind)]))

;; check-conn/pgm : Symbol String Symbol String -> Void
(define (check-conn/pgm who endp transport addr)
  (match addr
    [(regexp #rx"^([-a-zA-Z0-9.]+):([0-9]+);([-a-zA-Z0-9.]+):([0-9]+)$"
             (list _ ifc port peer-name peer-port))
     (check-net-bind who endp ifc port 'connect)
     (check-net-connect who endp peer-name peer-port)]
    [_ (bad-endp who endp 'connect)]))

;; check-*/ipc : Symbol String 'bind/'connect String -> Void
(define (check-*/ipc who endp mode addr)
  (cond [(regexp-match? #rx"^[*]?$" addr)
         (bad-endp who endp mode)]
        [(and (regexp-match? #rx"^@" addr) (regexp-match #rx"Linux" (system-type 'machine)))
         endp]
        [else
         (define path (cleanse-path (path->complete-path addr)))
         (security-guard-check-file who path '(read write))
         (format "ipc://~a" (path->string path))]))

;; check-net-bind : Symbol String String String ['bind/'connect] -> Void
(define (check-net-bind who endp ifc port [mode 'bind])
  (cond [(equal? ifc "*") (security-guard-check-network* who #f (string->number port) 'server)]
        [else (security-guard-check-network* who ifc (string->number port) 'server)]))

;; check-net-connect : Symbol String String String -> Void
(define (check-net-connect who endp peer-name peer-port)
  (security-guard-check-network* who peer-name (string->number peer-port) 'client))

;; bad-endp : Symbol String 'bind/'connect -> (escapes)
(define (bad-endp who endp mode)
  (error who "invalid endpoint or unsupported endpoint format~a\n  endpoint: ~a"
         (format ";\n cannot parse endpoint to check access permission; bypass with zmq-unsafe-~a" mode)
         endp))
