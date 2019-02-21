
build:
	dune build
	ln -Tsf _build/default/src/wodan-unix/wodanc.exe wodanc

deps:
	git submodule update --init --recursive
	opam install --deps-only -y . vendor/*/
	dune external-lib-deps --missing @@default

sync:
	git submodule sync --recursive
	git submodule update --init --recursive

ocamlformat:
	# Use the master version of ocamlformat for matching results
	git ls-files -- 'src/*.ml' 'src/*.mli' |grep -v 407 |xargs ocamlformat --inplace

fuzz:
	dune build src/wodan-unix/wodanc.exe
	afl-fuzz -i afl/input -o afl/output -- \
		_build/default/src/wodan-unix/wodanc.exe fuzz @@

test:
	dune runtest irmin-tests

install:
	dune install

uninstall:
	dune uninstall

clean:
	rm -rf _build _opam

.PHONY: build deps ocamlformat fuzz test install uninstall clean
