# mirage-storage

mirage-storage is a flash friendly, safe and flexible
filesystem library for Mirage OS.

Currently the basic disk format is implemented.

mirage-storage requires Opam, Mirage 3, and OCaml 4.04.

```
# Optional once Mirage 3 is released
#opam repo add mirage-dev https://github.com/mirage/mirage-dev.git

opam install mirage
opam pin add mirage-unikernel-storage-unix .
mirage configure --target unix
opam install mirage-unikernel-storage-unix
mirage build
```

