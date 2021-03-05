# zeromq-r

Racket bindings for ZeroMQ (aka 0MQ aka ZMQ).

The name of the repository is `racket-zeromq`.  
The name of the package is `zeromq-r`.  
The name of the collection is `zeromq`.  
Just so that's clear.

# Prerequisites

This package depends on the `libzmq` shared library, which must be
installed either in the operating system's default library search path
or in Racket's extended library search path (see
`get-lib-search-dirs`).

Instructions for common platforms:
- on Linux (Debian, Ubuntu, etc): `sudo apt install libzmq5`
- on Linux (Redhat, etc): `sudo yum install zeromq`
- on Mac OS with Homebrew: `brew install zeromq`
- on Windows: This package automatically installs `libzmq.dll` in Racket's `lib` directory through a dependency on the `zeromq-win32-{i386,x86_64}` package.

# Installation

Install and build the package and its dependencies with the following
command:
```
raco pkg install --auto zeromq-r
```

# Documentation

See https://docs.racket-lang.org/zeromq-r/
