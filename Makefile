
build:
	dune build
	ln -sf _build/default/src/wodan-unix/wodanc.exe wodanc

deps:
	opam install -t --deps-only .

ocamlformat:
	# Use ocamlformat.0.9
	dune build @fmt --auto-promote

fuzz: build
	afl-fuzz -i afl/input -o afl/output -- \
		_build/default/src/wodan-unix/wodanc.exe fuzz @@

test:
	dune runtest

install:
	dune install

uninstall:
	dune uninstall

clean:
	dune clean
	rm wodanc

.PHONY: build deps ocamlformat fuzz test install uninstall clean
