FROM docker://docker.io/ocaml/opam2
RUN git checkout master
RUN git pull -q origin master
RUN opam update --verbose
RUN opam remove travis-opam
ARG OCAML_VERSION
RUN opam switch set $OCAML_VERSION
RUN opam upgrade -y
RUN opam depext -ui travis-opam
RUN cp $(opam var bin)/ci-opam -t ~
RUN opam remove -a travis-opam
RUN mv ~/ci-opam -t $(opam var bin)
VOLUME /repo
WORKDIR /repo
#RUN PACKAGE=wodan-irmin PINS="$({ echo wodan.dev:.; for op in vendor/*/*.opam; do echo "$op" |sed -re 's#(vendor/.*/)(.*)\.opam#\2.dev:\1#'; done; } |xargs)" $(opam var bin)/ci-opam

