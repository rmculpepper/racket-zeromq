#lang racket/base
(require racket/contract/base
         (only-in "main.rkt" zmq-socket?)
         (only-in "private/ffi.rkt" zmq_ctx-pointer?)
         (submod "main.rkt" private-unsafe))
(provide (protect-out
          (contract-out
           [zmq-unsafe-get-ctx
            (-> (values zmq_ctx-pointer? any/c))]
           [zmq-unsafe-connect
            (->* [zmq-socket?] [] #:rest (listof connect-addr/c) void?)]
           [zmq-unsafe-bind
            (->* [zmq-socket?] [] #:rest (listof bind-addr/c) void?)])))
