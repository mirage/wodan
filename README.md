# Wodan

Wodan is a flash friendly, safe and flexible
filesystem library for Mirage OS.

Currently the basic disk format is implemented.

## Paper

This explains some of the design choices behind Wodan.

[ICFP 2017](https://icfp17.sigplan.org/event/ocaml-2017-papers-wodan-a-pure-ocaml-flash-aware-filesystem-library)

## Building, installing and running

Wodan requires Opam, Dune, Mirage 3, and OCaml 4.06.

An opam switch with flambda is recommended for performance reasons.

```
opam switch 4.06.1+fp+flambda
```

### Building the library

```
git submodule update --init
make deps
# Follow the opam instructions
make
```

## CLI usage

```
dune exec cli/wodanc.exe --help
```

At the moment the CLI supports creating filesystems, dumping and restoring data into them.

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
afl-fuzz -i afl/input -o afl/output -- \
  _build/default/cli/wodanc.exe fuzz @@
```

