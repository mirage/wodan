
.PHONY: build clean test install uninstall

DUNE_TARGETS := cli/wodanc.exe examples/irmin_example.exe examples/irmin_cli.exe

build:
	dune build $(DUNE_TARGETS)

deps:
	git submodule update --init
	opam install -y dune ctypes-foreign lwt_ppx
	dune external-lib-deps --missing $(DUNE_TARGETS)

locked:
	git submodule update --init
	opam install -y opam-lock
	opam install --switch=. ./wodan.opam.locked

update-lock:
	opam lock wodan.opam

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

.PHONY: build deps locked update-lock fuzz test install uninstall clean
