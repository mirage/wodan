#!/bin/bash
# Just a sketch
# Useful for testing things without waiting on Travis,
# but only slightly faster
# Using rootless podman, should work similarly with docker
# See CI-NOTES
podman build --build-arg OCAML_VERSION=4.09 . -v ~/.opam/download-cache:/home/opam/.opam/download-cache -v $PWD:/repo --tag local-build
podman run -it --userns=keep-id -v ~/.opam/download-cache:/home/opam/.opam/download-cache -v .:/repo -e PACKAGE=wodan-irmin -e PINS="$({ echo wodan.dev:.; for op in vendor/*/*.opam; do echo "$op" |sed -re 's#(vendor/.*/)(.*)\.opam#\2.dev:\1#'; done; } |xargs)" local-build ci-opam
