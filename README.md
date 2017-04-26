# mirage-storage

mirage-storage is a flash friendly, safe and flexible
filesystem library for Mirage OS.

Currently the basic disk format is implemented.

## Installing and running

mirage-storage requires Opam, Mirage 3, and OCaml 4.04.

Currently Mirage needs to be patched, see
<https://github.com/mirage/mirage/pull/800>.

The patched branch is available at
https://github.com/g2p/mirage.git master.

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

