
    git clone https://github.com/g2p/wodan

in wodan/:

    opam pin add -k path wodan.dev .
    opam pin add -k path wodan-unix.dev .

    edit $(opam config var prefix)/lib/wodan/META and:
        add checkseum.ocaml below checkseum

to build the solo5 hvt unikernel:

Add the following pins:

    opam pin add mirage-solo5.dev git+https://github.com/mato/mirage-solo5#fixes-for-wodan
    opam pin add mirage-block-solo5.dev git+https://github.com/mato/mirage-block-solo5#fixes-for-wodan

Then:

    mirage configure -t hvt --http=80
    mirage build

to run:

(once)

    ip tuntap add tap100 mode tap
    ip addr add 10.0.0.1/24 dev tap100
    ip link set dev tap100 up

(once to format image)

    rm disk.img; touch disk.img ; fallocate -z -l $((256*1024*3)) disk.img
    wodanc format disk.img; echo $?

    ./solo5-hvt --net=tap100 --disk=disk.img  ./http.hvt --logs=wodan:debug
