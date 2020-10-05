# As of 2020-10-01, the ocaml/opam2:latest tag wasn't updated for :4.11
# Advice from @samoht: don't use ocaml/opam2 for now, switch to ocurrent/opam
#FROM docker://docker.io/ocaml/opam2
#FROM docker://docker.io/ocurrent/opam
ARG OCAML_VERSION
FROM docker://docker.io/ocurrent/opam:alpine-3.12-ocaml-${OCAML_VERSION}
WORKDIR /home/opam/opam-repository
#RUN git checkout master
#RUN git pull -q origin master
#RUN opam update --verbose
RUN opam remove travis-opam
# ocurrent is single-switch, use tags in the FROM line
#RUN opam switch set $OCAML_VERSION
#RUN opam upgrade -y
RUN opam depext -ui --noninteractive travis-opam
RUN cp $(opam var bin)/ci-opam -t ~
RUN opam remove -a travis-opam
RUN mv ~/ci-opam -t $(opam var bin)
VOLUME /repo
WORKDIR /repo

