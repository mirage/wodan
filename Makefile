
build:
	dune build
	ln -sf _build/default/src/wodan-unix/wodanc.exe wodanc

deps:
	git submodule update --init --recursive
	opam install --deps-only -y . vendor/*/

sync:
	git submodule sync --recursive
	git submodule update --init --recursive

ocamlformat:
	# Use ocamlformat=0.11.0
	dune build @fmt --auto-promote

fuzz:
	dune build src/wodan-unix/wodanc.exe
	afl-fuzz -i afl/input -o afl/output -- \
		_build/default/src/wodan-unix/wodanc.exe fuzz @@

test:
	dune runtest tests

install:
	dune install

uninstall:
	dune uninstall

clean:
	rm -rf _build wodanc

.PHONY: build deps ocamlformat fuzz test install uninstall clean
