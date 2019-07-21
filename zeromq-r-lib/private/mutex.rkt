#lang racket/base
(require ffi/unsafe/atomic
         ffi/unsafe/schedule)
(provide make-mutex
         mutex-dead-evt
         mutex-acquire/dead-evt
         mutex-dead?
         mutex-try
         mutex-release
         call-with-mutex)

;; When a mutex is acquired, the owner is set to the acquiring thread
;; (rather, the thread-dead-evt of the acquiring thread). Since an
;; unsafe-poller is run in an unspecified thread, make `(sync mutex)`
;; generate a new mutex-request for the syncing thread.

;; An OwnerBox is (box-of (U #f Thread-Dead-Evt))

;; A Mutex is (mutex OwnerBox Dead-Evt Acquire/Dead-Evt) <: (evt-of 'acquired)
(struct mutex (ownerbox de ade)
  #:property prop:evt
  (lambda (self) (request-evt (mutex-ownerbox self) (current-thread-dead-evt) #f)))

;; An Acquire/Dead-Evt is (acquire/dead-evt OwnerBox) <: (evt-of (U 'acquired 'dead))
(struct acquire/dead-evt (ownerbox) #:mutable
  #:property prop:evt
  (lambda (self) (request-evt (acquire/dead-evt-ownerbox self) (current-thread-dead-evt) #t)))

;; A Dead-Evt is (dead-evt OwnerBox) <: (evt-of 'dead)
(struct dead-evt (ownerbox)
  #:property prop:evt
  (unsafe-poller
   (lambda (self wakeups)
     (case (-probe (dead-evt-ownerbox self) #f)
       [(dead) (values '(dead) #f)]
       [else   (values #f self)]))))

;; A Request-Evt is (request-evt OwnerBox Thread-Dead-Evt Boolean)
;;               <: (evt-of (U 'acquired 'dead))
(struct request-evt (ownerbox requester dead-ok?)
  #:property prop:evt
  (unsafe-poller
   (lambda (self wakeups)
     ;; Note: if wakeups, we can only cancel sleep, not commit to sync
     ;; choice, so don't actually take mutex in that mode.
     (case (-probe (request-evt-ownerbox self)
                   (if wakeups #f (request-evt-requester self)))
       [(acquired) (values '(acquired) #f)]
       [(dead)     (if (request-evt-dead-ok? self)
                       (values '(dead) #f)
                       (values #f self #;never-evt))] ;; Ack! See racket bug #2754
       [(unowned)  (values '(mutex:retry) #f)]
       [(#f)       (values #f self)]))))

;; -probe : OwnerBox (U #f Thread-Dead-Evt) -> (U 'acquired 'dead 'unowned #f)
;; A result of #f means owned by live thread.  An 'acquired result is only
;; possible if acquire is non-false. An 'unowned result is only possible if
;; acquire is #f.
(define (-probe ownerbox acquire)
  (cond [(unbox ownerbox)
         => (lambda (owner)
              (if (sync/timeout 0 owner) 'dead #f))]
        [acquire (begin (set-box! ownerbox acquire) 'acquired)]
        [else 'unowned]))

(define (current-thread-dead-evt) (thread-dead-evt (current-thread)))
(define (dead-error) (error 'call-with-mutex "mutex is dead"))

;; ------------------------------------------------------------

;; make-mutex : -> Mutex
(define (make-mutex)
  (define ownerbox (box #f))
  (define de (dead-evt ownerbox))
  (define ade (acquire/dead-evt ownerbox))
  (mutex ownerbox de ade))

(define (mutex-dead-evt m) (mutex-de m))
(define (mutex-acquire/dead-evt m) (mutex-ade m))

;; mutex-dead? : Mutex -> Boolean
(define (mutex-dead? m)
  (unless (mutex? m) (raise-argument-error 'mutex-dead? "mutex?" m))
  (cond [(unbox (mutex-ownerbox m))
         => (lambda (owner) (and (sync/timeout 0 owner) #f))]
        [else #f]))

;; mutex-try : Mutex [X] -> (U #f 'acquired X)
(define (mutex-try m [dead #f])
  (unless (mutex? m) (raise-argument-error 'mutex-try "mutex?" m))
  (start-atomic)
  (case (begin0 (-probe (mutex-ownerbox m) (current-thread-dead-evt)) (end-atomic))
    [(acquired) 'acquired]
    [(dead) dead]
    [(#f) #f]))

;; mutex-release : Mutex -> Void
(define (mutex-release m)
  (unless (mutex? m) (raise-argument-error 'mutex-release "mutex?" m))
  (define ownerbox (mutex-ownerbox m))
  (unless (eq? (unbox ownerbox) (current-thread-dead-evt))
    (error 'mutex-release "current thread does not own mutex"))
  (set-box! ownerbox #f))

;; call-with-mutex : Mutex (-> X) [...] -> X
(define (call-with-mutex m proc
                         #:release-on-escape? [release-on-escape? #t]
                         #:on-dead [on-dead dead-error])
  (unless (mutex? m) (raise-argument-error 'call-with-mutex "mutex?" m))
  (case (or (mutex-try m 'dead) (sync (mutex-ade m)))
    [(acquired)
     (dynamic-wind
       void
       (lambda ()
         (begin0 (call-with-continuation-barrier proc)
           (unless release-on-escape? (mutex-release m))))
       (lambda () (when release-on-escape? (mutex-release m))))]
    [(dead) (on-dead)]))
