
build:
	dune build
	ln -sf _build/default/src/wodan-unix/wodanc.exe wodanc

deps:
	opam install --deps-only --with-doc --with-test .

doc-deps:
	cargo install mdbook mdbook-toc

sync:
	git submodule sync --recursive
	git submodule update --init --recursive

ocamlformat:
	dune build @fmt --auto-promote

fuzz:
	dune build src/wodan-unix/wodanc.exe
	afl-fuzz -i afl/input -o afl/output -- \
		_build/default/src/wodan-unix/wodanc.exe fuzz @@

doc:
	dune build @doc
	mdbook build

test:
	dune runtest tests

install:
	dune install

uninstall:
	dune uninstall

clean:
	dune clean
	rm -f wodanc

.PHONY: build deps doc-deps ocamlformat fuzz doc test install uninstall clean
