
.PHONY: build clean test

build:
	jbuilder build @install runner/main.exe cli/wodan.exe --dev

test:
	jbuilder runtest

install:
	jbuilder install

uninstall:
	jbuilder uninstall

clean:
	rm -rf _build
