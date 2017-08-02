#lang scribble/manual
@(require scribble/manual
          scribble/basic
          scribble/example
          (for-label racket racket/contract racket/format zeromq))

@title{ZeroMQ: Distributed Messaging}
@author[@author+email["Ryan Culpepper" "ryanc@racket-lang.org"]]

@(define(zmqlink url-suffix . pre-flow)
   (apply hyperlink (format "http://api.zeromq.org/4-2:~a" url-suffix) pre-flow))

@(define(zglink url-suffix . pre-flow)
   (apply hyperlink (format "http://zguide.zeromq.org/~a" url-suffix) pre-flow))

This library provides bindings to the
@hyperlink["http://zeromq.org"]{ZeroMQ} distributed messaging library.

@defmodule[zeromq]

@; ----------------------------------------
@section[#:tag "intro"]{ZeroMQ Examples}

This section contains examples of using this library adapted from the
@hyperlink["http://zguide.zeromq.org/page:all"]{ZeroMQ Guide}.

@subsection[#:tag "hello-world"]{Hello World in ZeroMQ}

This example is adapted from
@zglink["page:all#Ask-and-Ye-Shall-Receive"]{Ask and Ye Shall
Receive}, which illustrates REP-REQ communication.

Here is the ``hello world'' server:

@racketblock[
(define responder (zmq-socket 'rep))
(zmq-bind responder "tcp://*:5555")
(let loop ()
  (define msg (zmq-recv-string responder))
  (printf "Server received: ~s\n" msg)
  (zmq-send responder "World")
  (loop))
]

The first two lines of the server could also be combined into one, as follows:
@racketblock[
(define responder (zmq-socket 'rep #:bind "tcp://*:5555"))
]

Here is the ``hello world'' client:

@racketblock[
(define requester (zmq-socket 'req #:connect "tcp://localhost:5555"))
(for ([request-number (in-range 10)])
  (printf "Client sending Hello #~s\n" request-number)
  (zmq-send requester "Hello")
  (define response (zmq-recv-string requester))
  (printf "Client received ~s (#~s)\n" response request-number))
(zmq-close requester)
]

@subsection[#:tag "..."]{Weather Reporting in ZeroMQ}

This example is adapted from
@zglink["page:all#Getting-the-Message-Out"]{Getting the Message Out},
which illustrates PUB-SUB communication.

Here's the weather update server:

@racketblock[
(define publisher (zmq-socket 'pub #:bind "tcp://*:5556"))
(let loop ()
  (define zip (~r (random #e1e5) #:precision 5 #:pad-string "0"))
  (define temp (- (random 215) 80))
  (define rhumid (+ (random 50) 10))
  (zmq-send publisher (format "~a ~a ~a" zip temp rhumid))
  (loop))
]

Here is the weather client:

@racketblock[
(define subscriber (zmq-socket 'sub #:connect "tcp://localhost:5556"))
(define myzip (~r (random #e1e5) #:precision 5 #:pad-string "0"))
(printf "Subscribing to ZIP code ~a only\n" myzip)
(zmq-subscribe subscriber (format "~a " myzip))
(define total-temp
  (for/sum ([update-number (in-range 100)])
    (define msg (zmq-recv-string subscriber))
    (define temp (let ([in (open-input-string msg)]) (read in) (read in)))
    (printf "Client got temperature update #~s: ~s\n" update-number temp)
    temp))
(printf "Average temperature for ZIP code ~s was ~s\n"
        myzip (~r (/ total-temp 100)))
(zmq-close subscriber)
]


@; ----------------------------------------
@section[#:tag "api"]{ZMQ Functions}

@defproc[(zmq-socket? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a ZMQ socket, @racket[#f] otherwise.
}

@defproc[(zmq-socket [type (or/c 'pair 'pub 'sub 'req 'rep 'dealer 'router
                                 'pull 'push 'xpub 'xsub 'stream)]
                     [#:identity identity (or/c bytes? #f) #f]
                     [#:bind bind-addrs (or/c string? (listof string?)) null]
                     [#:connect connect-addrs (or/c string? (listof string?)) null]
                     [#:subscribe subscriptions (or/c bytes? string? (listof (or/c bytes? string?))) null])
         zmq-socket?]{

Creates a new ZMQ socket of the given socket @racket[type] and
initializes it with @racket[identity], @racket[subscriptions],
@racket[bind-addrs], and @racket[connect-addrs] (in that order).

Unlike @tt{libzmq}, @racket[zmq-socket] creates sockets with a short
default ``linger'' period (@tt{ZMQ_LINGER}), to avoid blocking the
Racket VM when the underlying context is shut down. The linger period
can be changed with @racket[zmq-set-option].
}

@defproc[(zmq-close [s zmq-socket?]) void?]{

Close the socket. Further operations on the socket will raise an
error, except that @racket[zmq-close] may be called on an
already-closed socket.
}

@defproc[(zmq-closed? [s zmq-socket?]) boolean?]{

Returns @racket[#t] if the socket is closed, @racket[#f] otherwise.
}

@defproc[(zmq-list-endpoints [s zmq-socket?] [mode (or/c 'bind 'connect)])
         (listof string?)]{

List the endpoints the socket is bound or connected to (when
@racket[mode] is @racket['bind] or @racket['connect], respectively).
}

@deftogether[[
@defproc[(zmq-get-option [s zmq-socket?]
                         [option symbol?])
         (or/c exact-integer? bytes?)]
@defproc[(zmq-set-option [s zmq-socket?]
                         [option symbol?]
                         [value (or/c exact-integer? bytes?)])
         void?]
]]{

Gets or sets a socket option; see the API documentation for
@zmqlink["zmq-getsockopt"]{zmq_getsockopt} and
@zmqlink["zmq-setsockopt"]{zmq_setsockopt}, respectively. An option's
symbol is obtained from the name of the corresponding C constant by
removing the @litchar{ZMQ_} prefix and converting it to
lower-case. For example, @tt{ZMQ_IPV6} becomes @racket['ipv6] and
@tt{ZMQ_LAST_ENDPOINT} becomes @racket['last_endpoint]. Not all
options are supported. See also @racket[zmq-list-options].
}

@defproc[(zmq-list-options [filter (or/c 'get 'set)]) (listof symbol?)]{

Lists the options that this library supports for
@racket[zmq-get-option] or @racket[zmq-set-option] when
@racket[filter] is @racket['get] or @racket['set], respectively.
}

@deftogether[[
@defproc[(zmq-connect [s zmq-socket?] [addr string?] ...) void?]
@defproc[(zmq-bind    [s zmq-socket?] [addr string?] ...) void?]
@defproc[(zmq-disconnect [s zmq-socket?] [addr string?] ...) void?]
@defproc[(zmq-unbind     [s zmq-socket?] [addr string?] ...) void?]
]]{

}

@deftogether[[
@defproc[(zmq-subscribe   [s zmq-socket?] [subscription (or/c bytes? string?)] ...) void?]
@defproc[(zmq-unsubscribe [s zmq-socket?] [subscription (or/c bytes? string?)] ...) void?]
]]{

}

@deftogether[[
@defproc[(zmq-send  [s zmq-socket?] [msg-frame (or/c bytes? string?)] ...+) void?]
@defproc[(zmq-send* [s zmq-socket?] [msg (non-empty-listof (or/c bytes? string?))]) void?]
]]{

}

@deftogether[[
@defproc[(zmq-recv  [s zmq-socket?]) bytes?]
@defproc[(zmq-recv-string [s zmq-socket?]) string?]
]]

@defproc[(zmq-recv* [s zmq-socket?]) (listof bytes?)]
