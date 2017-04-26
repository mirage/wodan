# mirage-storage

mirage-storage is a flash friendly, safe and flexible
filesystem library for Mirage OS.

Currently the basic disk format is implemented.

## Installing and running

mirage-storage requires Opam, Mirage 3, and OCaml 4.04.

Currently Mirage needs to be pinned to the
[master version](https://github.com/mirage/mirage),
which contains <https://github.com/mirage/mirage/pull/800>.

```
opam install mirage
mirage configure --target unix
opam pin add mirage-unikernel-storage-unix .
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

