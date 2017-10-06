
.PHONY: build clean test

build:
	jbuilder build @install runner/main.exe cli/wodan.exe examples/irmin_example.exe examples/irmin_cli.exe --dev

test:
	jbuilder runtest

install:
	jbuilder install

uninstall:
	jbuilder uninstall

clean:
	rm -rf _build
