# Wodan

Wodan is a flash friendly, safe and flexible
filesystem library for Mirage OS.

Currently the basic disk format is implemented.

## Building, installing and running

Wodan requires Opam, Mirage 3, and OCaml 4.04.

An opam switch with flambda is recommended for performance reasons.

```
opam switch 4.04.1+fp+flambda
```

### Pinned dependencies

Currently Mirage needs to be pinned to the
[master version](https://github.com/mirage/mirage),
which contains <https://github.com/mirage/mirage/pull/800>.

Additionally, Lwt needs to be pinned to the [master version](https://github.com/ocsigen/lwt),
which contains <https://github.com/ocsigen/lwt/pull/374>.

```
opam pin add --dev-repo mirage
opam pin add --dev-repo lwt
opam pin add --dev-repo csv
```

### Building the library

```
opam install jbuilder mirage ctypes-foreign
jbuilder external-lib-deps --missing @install runner/main.exe # Follow the opam instructions
(cd runner; mirage configure --target unix)
make
```

### Running tests

```
_build/default/runner/main.exe
```

By default, tests will run using a ramdisk.
To use a file:

```
(cd runner; mirage configure --target unix --block=file)
make
touch runner/disk.img
fallocate -l$[16*2**20] -z runner/disk.img
_build/default/runner/main.exe
```

The file must be cleared (using fallocate) before each run.
This is because tests create a new filesystem instance which,
until we get discard support, requires a clear disk.

### Running American Fuzzy Lop (AFL)

This requires OCaml 4.05 and pinned versions of several dependencies.

```
opam switch 4.05.0+trunk+afl
opam pin add ppx_deriving https://github.com/whitequark/ppx_deriving.git
opam pin add nocrypto https://github.com/vbmithr/ocaml-nocrypto.git#no-sexp
```

