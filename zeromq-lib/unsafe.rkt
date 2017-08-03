#lang racket/base
(require racket/contract/base
         (only-in "main.rkt" zmq-socket?)
         (submod "main.rkt" private-unsafe))
(provide (protect-out
          (contract-out
           [zmq-unsafe-connect
            (->* [zmq-socket?] [] #:rest (listof connect-addr/c) void?)]
           [zmq-unsafe-bind
            (->* [zmq-socket?] [] #:rest (listof bind-addr/c) void?)])))
