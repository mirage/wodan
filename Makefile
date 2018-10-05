
.PHONY: build clean test install uninstall

DUNE_TARGETS := cli/wodanc.exe examples/irmin_cli.exe

build:
	dune build $(DUNE_TARGETS)

deps:
	git submodule update --init
	opam install -y dune ctypes-foreign lwt_ppx opam-lock
	dune external-lib-deps --missing $(DUNE_TARGETS)

locked:
	git submodule update --init
	opam switch create --switch=.
	opam install -y --deps-only --switch=. ./wodan.opam.locked

locked-travis:
	git submodule update --init
	opam install -y --deps-only ./wodan.opam.locked

update-lock:
	opam lock wodan.opam
	# Workaround https://github.com/AltGr/opam-lock/issues/2
	sed -i '/"ocaml"/d; /"seq"/d; /"diet"/d; /"irmin"/d; /"irmin-chunk"/d; /"irmin-mem"/d;' wodan.opam.locked
	# We want Dune to find dependencies recursively inside submodules, but -p would inhibit that
	# There is an impedance mismatch between using Opam files for installing a package
	# and using them only for installing development dependencies.
	sed -i 's/"dune" "build" "-p" name "-j" jobs/"dune" "build" "-j" jobs/' wodan.opam.locked

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
	rm -rf _build

.PHONY: build deps locked locked-travis update-lock fuzz test install uninstall clean
