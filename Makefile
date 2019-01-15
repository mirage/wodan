OPAMS := wodan.opam wodan-irmin.opam wodan-unix.opam
LOCKED_OPAMS := $(patsubst %.opam, %.opam.locked, $(OPAMS))

build:
	dune build
	ln -Tsf _build/default/src/wodan-unix/wodanc.exe wodanc

deps:
	git submodule update --init --recursive
	opam install -y dune opam-lock lwt_ppx
	dune external-lib-deps --missing @@default

sync:
	git submodule sync --recursive
	git submodule update --init --recursive

%.opam.locked: %.opam
	opam lock $^
	# Workaround https://github.com/AltGr/opam-lock/issues/2
	sed -i '/{= "dev"}/d; /"ocaml"/d; /"ocaml-src"/d; /"ocaml-variants"/d; /"mirage-block/d; /"yaml"/d; /"seq"/d; /"wodan"/d; /"irmin"/d; /"irmin-chunk"/d; /"irmin-mem"/d;' $@
	gawk -i inplace '/pin-depends/{exit}1' $@

locked:
	git submodule update --init
	opam switch create .
	opam install -y --deps-only --switch=. $(patsubst %, ./%, $(LOCKED_OPAMS))

locked-travis:
	git submodule update --init
	opam install -y --deps-only $(patsubst %, ./%, $(LOCKED_OPAMS))

update-lock: $(LOCKED_OPAMS)

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

.PHONY: build deps locked locked-travis update-lock fuzz test install uninstall clean
