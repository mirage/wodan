
.PHONY: build clean test install uninstall

JBUILDER_TARGETS := @install runner/main.exe cli/wodanc.exe examples/irmin_example.exe examples/irmin_cli.exe

build:
	jbuilder build --dev $(JBUILDER_TARGETS)

deps:
	opam install -y jbuilder mirage ctypes-foreign
	jbuilder external-lib-deps --missing $(JBUILDER_TARGETS)


test:
	jbuilder runtest

install:
	jbuilder install

uninstall:
	jbuilder uninstall

clean:
	rm -rf _build
