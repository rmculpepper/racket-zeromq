#lang info

;; ========================================
;; pkg info

(define collection "zeromq")
(define deps
  '(["base" #:version "6.12"]))

;; ========================================
;; collect info

(define name "zeromq")

;; Makes no changes, just prints warning if ffi lib not found.
(define post-install-collection "private/install.rkt")
