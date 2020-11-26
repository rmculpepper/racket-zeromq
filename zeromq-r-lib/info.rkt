#lang info

;; ========================================
;; pkg info

(define version "1.2")
(define collection "zeromq")
(define deps
  '(["base" #:version "7.0"]
    ["zeromq-win32-i386" #:platform "win32\\i386"]
    ["zeromq-win32-x86_64" #:platform "win32\\x86_64"]
    ["zeromq-x86_64-linux-natipkg" #:platform "x86_64-linux-natipkg"]))

;; ========================================
;; collect info

(define name "zeromq")

;; Makes no changes, just prints warning if ffi lib not found.
(define post-install-collection "private/install.rkt")
