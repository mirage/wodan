# Wodan

Wodan is a flash friendly, safe and flexible
filesystem library for Mirage OS.

Currently the basic disk format is implemented.

## Building, installing and running

Wodan requires Opam, Mirage 3, and OCaml 4.04.

### Pinned dependencies

Currently Mirage needs to be pinned to the
[master version](https://github.com/mirage/mirage),
which contains <https://github.com/mirage/mirage/pull/800>.

Additionally, Lwt needs to be pinned to the [master version](https://github.com/ocsigen/lwt),
which contains <https://github.com/ocsigen/lwt/pull/374>.

```
opam pin add mirage https://github.com/mirage/mirage.git
opam pin add lwt https://github.com/ocsigen/lwt.git
```

### Building the library

```
make
```

### Running tests

```
cd runner
opam install mirage
mirage configure --target unix
make depend
mirage build
./storage
```

By default, tests will run using a ramdisk.
To use a file:

```
mirage configure --target unix --block=file
make
fallocate -l$[16*2**20] -z disk.img
./storage
```

The file must be cleared (using fallocate) before each run.
This is because tests create a new filesystem instance which,
until we get discard support, requires a clear disk.

### Running American Fuzzy Lop (AFL)

This requires OCaml 4.05 and pinned versions of several dependencies
(the no-sexp branch of nocrypto by vbmithr, the master branch of
ppx_deriving).


