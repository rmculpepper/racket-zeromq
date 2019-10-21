#lang scribble/manual
@(require racket/runtime-path
          scribble/manual
          scribble/basic
          scribble/example
          (for-label racket racket/match racket/contract racket/format
                     setup/dirs zeromq zeromq/unsafe))

@title{ZeroMQ: Distributed Messaging}
@author[@author+email["Ryan Culpepper" "ryanc@racket-lang.org"]]

@(define(zmqlink url-suffix . pre-flow)
   (apply hyperlink (format "http://api.zeromq.org/master:~a" url-suffix) pre-flow))

@(define(zglink url-suffix . pre-flow)
   (apply hyperlink (format "http://zguide.zeromq.org/~a" url-suffix) pre-flow))

@(define EVT
   @elem{@tech[#:doc '(lib "scribblings/reference/reference.scrbl")]{synchronizable event}
         (@racket[evt?])})

@(begin
  (define-runtime-path log-file "private/log-for-zeromq.rktd")
  (define the-eval (make-log-based-eval log-file 'replay))
  (the-eval '(require racket/match racket/format zeromq))
  ;; Silence threads stopped by break-thread (kill-thread doesn't work)
  (the-eval '(uncaught-exception-handler
              (lambda _ (abort-current-continuation (default-continuation-prompt-tag) void)))))

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

@examples[#:eval the-eval #:label #f
(define responder-thread
  (thread
    (lambda ()
      (define responder (zmq-socket 'rep))
      (zmq-bind responder "tcp://*:5555")
      (let loop ()
        (define msg (zmq-recv-string responder))
        (printf "Server received: ~s\n" msg)
        (zmq-send responder "World")
        (loop)))))
]

The @racket[responder] socket could have been created and connected to
its address in one call, as follows:
@racketblock[
(define responder (zmq-socket 'rep #:bind "tcp://*:5555"))
]

Here is the ``hello world'' client:

@examples[#:eval the-eval #:label #f
(define requester (zmq-socket 'req #:connect "tcp://localhost:5555"))
(for ([request-number (in-range 3)])
  (zmq-send requester "Hello")
  (define response (zmq-recv-string requester))
  (printf "Client received ~s (#~s)\n" response request-number))
(zmq-close requester)
]

@examples[#:eval the-eval #:hidden
(break-thread responder-thread)
]

@subsection[#:tag "weather"]{Weather Reporting in ZeroMQ}

This example is adapted from
@zglink["page:all#Getting-the-Message-Out"]{Getting the Message Out},
which illustrates PUB-SUB communication.

Here's the weather update server:

@examples[#:eval the-eval #:label #f
(define (zip->string zip) (~r zip #:precision 5 #:pad-string "0"))
(eval:alts (define (random-zip) (random #e1e5))
           (define (random-zip) 10001)) ;; use loaded dice for faster doc build
(define publisher-thread
  (thread
    (lambda ()
      (define publisher (zmq-socket 'pub #:bind "tcp://*:5556"))
      (let loop ()
        (define zip (zip->string (random-zip)))
        (define temp (- (random 215) 80))
        (define rhumid (+ (random 50) 10))
        (zmq-send publisher (format "~a ~a ~a" zip temp rhumid))
        (loop)))))
]

Here is the weather client:

@examples[#:eval the-eval #:label #f
(define subscriber (zmq-socket 'sub #:connect "tcp://localhost:5556"))
(define myzip (zip->string (random-zip)))
(printf "Subscribing to ZIP code ~a only\n" myzip)
(zmq-subscribe subscriber myzip)
(define total-temp
  (for/sum ([update-number (in-range 10)])
    (define msg (zmq-recv-string subscriber))
    (define temp (let ([in (open-input-string msg)]) (read in) (read in)))
    (printf "Client got temperature update #~s: ~s\n" update-number temp)
    temp))
(printf "Average temperature for ZIP code ~s was ~s\n"
        myzip (~r (/ total-temp 10)))
(zmq-close subscriber)
]

@examples[#:eval the-eval #:hidden
(break-thread publisher-thread)
]


@subsection[#:tag "divide-and-conquer"]{Divide and Conquer in ZeroMQ}

This example is adapted from
@zglink["page:all#Divide-and-Conquer"]{Divide and Conquer},
which illustrates PUSH-PULL communication.

Here's the ventilator:

@examples[#:eval the-eval #:label #f
(code:comment "Task ventilator")
(code:comment "Binds PUSH socket to tcp://localhost:5557")
(code:comment "Sends batch of tasks to workers via that socket")
(define (ventilator go-sema)
  (define sender (zmq-socket 'push #:bind "tcp://*:5557"))
  (define sink (zmq-socket 'push #:connect "tcp://localhost:5558"))
  (semaphore-wait go-sema)
  (zmq-send sink "0") (code:comment "message 0 signals start of batch")
  (define total-msec
    (for/fold ([total 0]) ([task-number (in-range 100)])
      (define workload (add1 (random 100)))
      (zmq-send sender (format "~s" workload))
      (+ total workload)))
  (printf "Total expected cost: ~s msec\n" total-msec)
  (zmq-close sender)
  (zmq-close sink))
]

Here are the workers:

@examples[#:eval the-eval #:label #f
(code:comment "Task worker")
(code:comment "Connects PULL socket to tcp://localhost:5557")
(code:comment "Collects workloads from ventilator via that socket")
(code:comment "Connects PUSH socket to tcp://localhost:5558")
(code:comment "Sends results to sink via that socket")
(define (worker)
  (define receiver (zmq-socket 'pull #:connect "tcp://localhost:5557"))
  (define sender (zmq-socket 'push #:connect "tcp://localhost:5558"))
  (let loop ()
    (define s (zmq-recv-string receiver))
    (sleep (/ (read (open-input-string s)) 1000)) (code:comment "do the work")
    (zmq-send sender "")
    (loop)))
]

Here is the sink:

@examples[#:eval the-eval #:label #f
(code:comment "Task sink")
(code:comment "Binds PULL socket to tcp://localhost:5558")
(code:comment "Collects results from workers via that socket")
(define (sink)
  (define receiver (zmq-socket 'pull #:bind "tcp://*:5558"))
  (void (zmq-recv receiver)) (code:comment "start of batch")
  (time (for ([task-number (in-range 100)])
          (void (zmq-recv receiver))))
  (zmq-close receiver))
]

Now we create a sink thread, a ventilator thread, and 10 worker
threads. We give them a little time to connect to each other, then we
start the task ventilator and wait for the sink to collect the
results.

@examples[#:eval the-eval #:label #f
(let ()
  (define go-sema (make-semaphore 0))
  (define sink-thread (thread sink))
  (define ventilator-thread (thread (lambda () (ventilator go-sema))))
  (define worker-threads (for/list ([i 10]) (thread worker)))
  (code:comment "Give the threads some time to connect...")
  (begin (sleep 1) (semaphore-post go-sema))
  (void (sync sink-thread)))
]

Note that to achieve the desired parallel speedup here, it's important
to give all of the worker threads time to connect their receiver
sockets---the @racket[(sleep 1)] is a blunt way of doing
this. Otherwise, the first thread to connect might end up doing all of
the work---an example of the ``slow joiner'' problem (see the end of
@zglink["page:all#Divide-and-Conquer"]{Divide and Conquer} for more
details).


@; ----------------------------------------
@section[#:tag "api"]{ZeroMQ API}

@defproc[(zmq-available?) boolean?]{

Returns @racket[#t] if the ZeroMQ library (@tt{libzmq}) was loaded successfully,
@racket[#f] otherwise. If the result is @racket[#f], calling
@racket[zmq-socket] will raise an exception. See @secref["deps"].

@history[#:added "1.1"]
}

@defproc[(zmq-version)
         (or/c (list/c exact-nonnegative-integer?
                       exact-nonnegative-integer?
                       exact-nonnegative-integer?)
               #f)]{

Returns the version of the ZeroMQ library (@tt{libzmq}) if it was
loaded successfully, @racket[#f] otherwise. The version is represented
by a list of three integers---for example, @racket['(4 3 2)].

@history[#:added "1.1"]
}

@subsection[#:tag "socket-api"]{Managing ZeroMQ Sockets}

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

A ZeroMQ socket acts as a @EVT that is ready when
@racket[zmq-recv-message] would receive a message without blocking;
the synchronization result is the received message
(@racket[zmq-message?]). If the socket is closed, it is never ready
for synchronization; use @racket[zmq-closed-evt] to detect closed
sockets.

Unlike @tt{libzmq}, @racket[zmq-socket] creates sockets with a short
default ``linger'' period (@tt{ZMQ_LINGER}), to avoid blocking the
Racket VM when the underlying context is shut down. The linger period
can be changed with @racket[zmq-set-option].
}

@defproc[(zmq-socket? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a ZeroMQ socket, @racket[#f] otherwise.
}

@defproc[(zmq-close [s zmq-socket?]) void?]{

Close the socket. Further operations on the socket will raise an
error, except that @racket[zmq-close] may be called on an
already-closed socket.
}

@defproc[(zmq-closed? [s zmq-socket?]) boolean?]{

Returns @racket[#t] if the socket is closed, @racket[#f] otherwise.
}

@defproc[(zmq-closed-evt [s zmq-socket?]) evt?]{

Returns a @EVT that is ready for synchronization when @racket[(zmq-closed?
s)] would return @racket[#t]. The synchronization result is the event itself.
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

@defproc[(zmq-list-options [mode (or/c 'get 'set)]) (listof symbol?)]{

Lists the options that this library supports for
@racket[zmq-get-option] or @racket[zmq-set-option] when
@racket[mode] is @racket['get] or @racket['set], respectively.
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
endpoint format.'' The parsing and access control check can be skipped
by using @racket[zmq-unsafe-connect] or @racket[zmq-unsafe-bind]
instead.
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

@; ----------------------------------------
@subsection[#:tag "message-api"]{Sending and Receiving ZeroMQ Messages}

A @deftech{ZeroMQ message} consists of one or more @emph{frames}
(represented by byte strings). The procedures in this library support
sending and receiving only complete messages (as opposed to the
frame-at-a-time operations in the @tt{libzmq} C library).

@defproc[(zmq-message? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a ZeroMQ message value, @racket[#f]
otherwise.
}

@defproc[#:kind "procedure & match pattern"
         (zmq-message [frames (or/c bytes? string? (listof (or/c bytes? string?)))])
          zmq-message?]{

Returns a ZeroMQ message value consisting of the given @racket[frames]. Strings
are automatically coerced to bytestrings using @racket[string->bytes/utf-8],
and if a single string or bytestring is given, it is converted to a
singleton list.

When used a @racket[match] pattern, the @racket[frames] subpattern is always
matched against a list of bytestrings.

@examples[#:eval the-eval
(define msg (zmq-message "hello world"))
(match msg [(zmq-message frames) frames])
]

In @tt{libzmq} version 4.3.2, the draft (unstable) API has additional
operations on messages to support the draft socket types; for example, a
message used with a CLIENT or SERVER socket has a @emph{routing-id}
field. Support will be added to @racket[zmq-message] when the corresponding
draft APIs become stable.

@history[#:added "1.1"]
}

@defproc[(zmq-send-message [s zmq-socket] [msg zmq-message?]) void?]{

Sends the message @racket[msg] on socket @racket[s].

@history[#:added "1.1"]
}

@defproc[(zmq-recv-message [s zmq-socket?]) zmq-message?]{

Receives a message from socket @racket[s].

@history[#:added "1.1"]
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

@defproc[(zmq-proxy [sock1 zmq-socket?]
                    [sock2 zmq-socket?]
                    [#:capture capture (-> zmq-socket? zmq-message? any) void]
                    [#:other-evt other-evt evt? never-evt])
         any]{

Runs a proxy connecting @racket[sock1] and @racket[sock2]; a loop
reads a message from either socket and sends it to the other. For each
message received, the @racket[capture] procedure is called on the
receiving socket and the received message, and then the message is
forwarded to the other socket.

This procedure returns only when the proxy is finished, either because
one of the sockets is closed---in which case @racket[(void)] is
returned---or because @racket[other-evt] became ready for
synchronization---in which case @racket[other-evt]'s synchronization
result is returned. The procedure might also raise an exception due to
a failed send or receive or if @racket[capture] or @racket[other-evt]
raise an exception.

@history[#:added "1.1"]
}

@; ============================================================
@section[#:tag "unsafe"]{ZeroMQ Unsafe Functions}

The functions provided by this module are @emph{unsafe}.

@defmodule[zeromq/unsafe]

@deftogether[[
@defproc[(zmq-unsafe-connect [s zmq-socket?] [endpoint string?] ...) void?]
@defproc[(zmq-unsafe-bind    [s zmq-socket?] [endpoint string?] ...) void?]
]]{

Like @racket[zmq-connect] and @racket[zmq-bind], but do not attempt to
parse the @racket[endpoint] arguments and perform security guard
checks.

These functions are unsafe, not in the sense that misuse is likely to
cause memory corruption, but in the sense that they do not respect the
current @tech[#:doc '(lib "scribblings/reference/reference.scrbl")]{security
guard}.
}

@; ----------------------------------------
@section[#:tag "deps"]{ZeroMQ Requirements}

This library requires the @tt{libzmq} foreign library to be installed
in either the operating system's default library search path or in
Racket's extended library search path (see @racket[get-lib-search-dirs]).

On Linux, @tt{libzmq.so.5} is required. On Debian-based systems, it is
available from the @tt{libzmq5} package. On RedHat-based systems, it
is available from the @tt{zeromq} package.

On Mac OS, @tt{libzmq.5.dylib} is required.
@itemlist[
@item{With Homebrew: Run @tt{brew install zeromq}. The library will be
installed in @tt{/usr/local/lib}, which is in the operating system's
default search path.}
@item{With MacPorts: Install the @tt{zmq} port. The library will be
installed in @tt{/opt/local/lib}, which is @emph{not} in the operating
system's default search path. Manually copy or link the library into
one of the directories returned by @racket[(get-lib-search-dirs)].}
]

On Windows, @tt{libzmq.dll} is required. It is automatically installed
via the @tt{zeromq-win32-{i386,x86_64}} package.

@(close-eval the-eval)
