OPAMS := wodan.opam wodan-irmin.opam wodan-unix.opam
LOCKED_OPAMS := $(patsubst %.opam, %.opam.locked, $(OPAMS))

build:
	dune build

deps:
	git submodule update --init
	opam install -y dune lwt_ppx opam-lock
	dune external-lib-deps --missing

%.opam.locked: %.opam
	opam lock $^
	# Workaround https://github.com/AltGr/opam-lock/issues/2
	sed -i '/"ocaml"/d; /"seq"/d; /"wodan"/d; /"irmin"/d; /"irmin-chunk"/d; /"irmin-mem"/d;' $@
	gawk -i inplace '/pin-depends/{exit}1' $@

locked:
	git submodule update --init
	opam switch create --switch=.
	opam install -y --deps-only --switch=. $(patsubst %, ./%, $(LOCKED_OPAMS))

locked-travis:
	git submodule update --init
	opam install -y --deps-only $(patsubst %, ./%, $(LOCKED_OPAMS))

update-lock: $(LOCKED_OPAMS)

fuzz:
	dune build cli/wodanc.exe
	afl-fuzz -i afl/input -o afl/output -- \
		_build/default/cli/wodanc.exe fuzz @@

test:
	dune runtest irmin-tests

install:
	dune install

uninstall:
	dune uninstall

clean:
	rm -rf _build _opam

.PHONY: build deps locked locked-travis update-lock fuzz test install uninstall clean
