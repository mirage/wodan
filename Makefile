
.PHONY: build clean test install uninstall

DUNE_TARGETS := cli/wodanc.exe examples/irmin_example.exe examples/irmin_cli.exe

build:
	dune build $(DUNE_TARGETS)

deps:
	opam install -y dune ctypes-foreign lwt_ppx
	dune external-lib-deps --missing $(DUNE_TARGETS)

test:
	dune runtest irmin-tests

install:
	dune install

uninstall:
	dune uninstall

clean:
	rm -rf _build
