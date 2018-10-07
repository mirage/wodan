# Wodan

[![Build Status](https://travis-ci.org/g2p/wodan.svg?branch=master)](https://travis-ci.org/g2p/wodan)

Wodan is a flash friendly, safe and flexible
filesystem library for Mirage OS.

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

### Building the library

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
dune exec cli/wodanc.exe --help
```

At the moment the CLI supports creating filesystems, dumping and
restoring data into them.

### Running tests

```
make test
dune exec cli/wodanc.exe exercise
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

