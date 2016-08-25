#lang info

;; ========================================
;; pkg info

(define collection "zeromq")
(define deps
  '(["base"]))
(define build-deps
  '("racket-doc"
    "scribble-lib"))

;; ========================================
;; collect info

(define name "zeromq")
(define scribblings
  '(["zeromq.scrbl" ()]))
