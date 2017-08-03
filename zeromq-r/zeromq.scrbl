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
@hyperlink["http://zeromq.org"]{ZeroMQ} (or ``@as-index{0MQ}'', or
``@as-index{ZMQ}'') distributed messaging library.

@defmodule[zeromq]

This package is distributed under the
@hyperlink["https://www.gnu.org/licenses/lgpl.html"]{GNU Lesser
General Public License (LGPL)}. As a client of this library you must
also comply with the @hyperlink["http://zeromq.org/area:licensing"]{
@tt{libzmq} license}.

@; ----------------------------------------
@section[#:tag "intro"]{ZeroMQ Examples}

This section contains examples of using this library adapted from the
@hyperlink["http://zguide.zeromq.org/page:all"]{0MQ Guide}.

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
@section[#:tag "api"]{ZeroMQ Functions}

@defproc[(zmq-socket? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a ZeroMQ socket, @racket[#f] otherwise.
}

@defproc[(zmq-socket [type (or/c 'pair 'pub 'sub 'req 'rep 'dealer 'router
                                 'pull 'push 'xpub 'xsub 'stream)]
                     [#:identity identity (or/c bytes? #f) #f]
                     [#:bind bind-endpoints (or/c string? (listof string?)) null]
                     [#:connect connect-endpoints (or/c string? (listof string?)) null]
                     [#:subscribe subscriptions (or/c bytes? string? (listof (or/c bytes? string?))) null])
         zmq-socket?]{

Creates a new ZeroMQ socket of the given socket @racket[type] and
initializes it with @racket[identity], @racket[subscriptions],
@racket[bind-endpoints], and @racket[connect-endpoints] (in that order).

See the @zmqlink["zmq-socket"]{zmq_socket} documentation for brief
descriptions of the different @racket[type]s of sockets, and see the
@zglink["page:all"]{0MQ Guide} for more detailed explanations.

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
@defproc[(zmq-connect [s zmq-socket?] [endpoint string?] ...) void?]
@defproc[(zmq-bind    [s zmq-socket?] [endpoint string?] ...) void?]
]]{

Connect or bind the socket @racket[s] to the given @racket[endpoint](s).

See the transport documentation pages (@zmqlink["zmq-tcp"]{tcp},
@zmqlink["zmq-pgm"]{pgm}, @zmqlink["zmq-ipc"]{ipc},
@zmqlink["zmq-inproc"]{inproc}, @zmqlink["zmq-vmci"]{vmci},
@zmqlink["zmq-udp"]{udp}) for more information about transports and
their @racket[endpoint] notations.

If @racket[endpoint] refers to a filesystem path or network address,
access is checked against @racket[(current-security-guard)]. This
library cannot parse and check all endpoint formats supported by
@tt{libzmq}; if @racket[endpoint] is not in a supported format, an
exception is raised with the message ``invalid endpoint or unsupported
endpoint format.'' Clients may skip the parsing and access control
check by using @racket[zmq-unsafe-connect] or
@racket[zmq-unsafe-bind].
}

@deftogether[[
@defproc[(zmq-disconnect [s zmq-socket?] [endpoint string?] ...) void?]
@defproc[(zmq-unbind     [s zmq-socket?] [endpoint string?] ...) void?]
]]{

Disconnect or unbind the socket @racket[s] from the given @racket[endpoint](s).

Note that in some cases @racket[endpoint] must be more specific than the
argument to @racket[zmq-bind] or @racket[zmq-connect]. For example, see
the section labeled ``Unbinding wild-card address from a socket'' in
@zmqlink["zmq-tcp"]{zmq_tcp}.
}

@deftogether[[
@defproc[(zmq-subscribe   [s zmq-socket?] [topic (or/c bytes? string?)] ...) void?]
@defproc[(zmq-unsubscribe [s zmq-socket?] [topic (or/c bytes? string?)] ...) void?]
]]{

Adds or removes @racket[topic] from a SUB (@racket['sub]) socket's
subscription list. A SUB socket starts out with no subscriptions, and
thus receives no messages.

A @racket[topic] matches a message if @racket[topic] is a prefix of
the message. The empty topic accepts all messages.
}

@defproc[(zmq-send  [s zmq-socket?] [msg-frame (or/c bytes? string?)] ...+) void?]{

Sends a message on socket @racket[s]. The message has as many frames
as @racket[msg-frame] arguments, with at least one frame required.
}

@defproc[(zmq-send* [s zmq-socket?] [msg (non-empty-listof (or/c bytes? string?))]) void?]{

Sends the message @racket[msg] on socket @racket[s], where
@racket[msg] consists of a non-empty list of frames.
}

@deftogether[[
@defproc[(zmq-recv  [s zmq-socket?]) bytes?]
@defproc[(zmq-recv-string [s zmq-socket?]) string?]
]]{

Receives a one-frame message from the socket @racket[s] and returns
the single frame as a byte string or character string, respectively.

If a multi-frame message is received from @racket[s], an error is
raised. (The message is still consumed.)
}

@defproc[(zmq-recv* [s zmq-socket?]) (listof bytes?)]{

Receives a message from the socket @racket[s]. The message is
represented as a list of byte strings, one for each frame.
}

@section[#:tag "unafe"]{ZeroMQ Unsafe Functions}

The functions provided by this module are @emph{unsafe}.

@defmodule[zeromq/unsafe]

@deftogether[[
@defproc[(zmq-connect [s zmq-socket?] [endpoint string?] ...) void?]
@defproc[(zmq-bind    [s zmq-socket?] [endpoint string?] ...) void?]
]]{

Like @racket[zmq-connect] and @racket[zmq-bind], but do not attempt to
parse the @racket[endpoint] arguments and perform security guard
checks.

These functions are unsafe, not in the sense that misuse is likely to
cause memory corruption, but in the sense that they do not respect the
security guard mechanism.
}
