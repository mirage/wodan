# Wodan

Wodan is a flash friendly, safe and flexible
filesystem library for Mirage OS.

It provides a key-value store as well as an Irmin backend.

[![Build Status](https://travis-ci.org/g2p/wodan.svg?branch=master)](https://travis-ci.org/g2p/wodan)

## Status

Wodan works, but still needs more hardening and more testing in
concurrent environments.

The store it provides is usable for basic tasks, but Wodan itself
doesn't provide ways to serialize complex objects or deal with
non-fixed size keys or values larger than 64k.  You are expected
to layer a higher-level store such as Irmin on top of it for such
amenities.

To get the best performance out of Wodan, you are also expected
to understand some of the tradeoffs involved in flushing data to
disk and picking a block size.

## Documentation

Unikernel usage is best explained through an example.

See
https://github.com/mato/camel-service/tree/master/counter-wodan
and the README file it contains for an overview.

## Paper

This explains some of the design choices behind Wodan.

[ICFP 2017](https://icfp17.sigplan.org/event/ocaml-2017-papers-wodan-a-pure-ocaml-flash-aware-filesystem-library)

## Building, installing and running

Wodan requires [Opam][opam], [Dune][dune], [Mirage 3][mirage],
and [OCaml 4.06][ocaml].

An opam switch with flambda is recommended for performance reasons.

```
opam switch 4.06.1+fp+flambda
```

### Building the library, CLI, and Irmin bindings

```
make deps
# Follow the opam instructions
make
```

Alternatively, you can do:
```
make locked
```
to build a local Opam switch with known good versions of all
dependencies.

## CLI usage

```
./wodanc --help
```

If wodan-unix has been installed (or pinned) through Opam,
you can instead type:

```
wodanc --help
```

When developping, you may prefer to use the following for
immediate feedback on any changes:

```
dune exec src/wodan-unix/wodanc.exe
```

At the moment the CLI supports creating filesystems, dumping and
restoring data into them, plus some more specialised features
explained below.

### Micro-benchmarking

```
./wodanc bench
```

### Running tests

```
make test
./wodanc exercise
```

### Running American Fuzzy Lop (AFL)

This requires OCaml compiled with AFL support.

```
opam switch 4.06.1+afl
sudo sysctl kernel.core_pattern=core
echo performance |sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
make fuzz
```

[opam]: https://opam.ocaml.org/
[dune]: https://github.com/ocaml/dune#installation
[mirage]: https://mirage.io/
[ocaml]: https://ocaml.org/

