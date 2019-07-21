#lang racket/base
(require rackunit
         zeromq/private/mutex)

(let ()
  (define m (make-mutex))
  (define xs null)
  (define threads
    (for/list ([i 10])
      (thread
       (lambda ()
         (for ([j 10])
           (call-with-mutex m
             (lambda ()
               (set! xs (begin0 (append xs (list (list i j))) (sleep 0.01))))))))))
  (for-each sync threads)
  (for* ([i 10] [j 10]) (check member (list i j) xs)))

(let ()
  (define m (make-mutex))
  (define bad-thread
    (thread (lambda () (call-with-mutex m (lambda () (kill-thread (current-thread)))))))
  (sync bad-thread)
  (check-eq? (mutex-try m 'dead) 'dead)
  (check-eq? (sync/timeout 0.1 m) #f)
  (check-eq? (sync (mutex-acquire/dead-evt m)) 'dead)
  (check-eq? (sync (mutex-dead-evt m)) 'dead))
