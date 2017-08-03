#lang info

;; ========================================
;; pkg info

(define collection "zeromq")
(define deps
  '(["base" #:version "6.10"]
    "zeromq-lib"
    "rackunit-lib"))
(define build-deps
  '("racket-doc"
    "scribble-lib"))
(define implies
  '("zeromq-lib"))

;; ========================================
;; collect info

(define name "zeromq")
(define scribblings '(["zeromq.scrbl" ()]))