open Mirage

let stack = generic_stackv4 default_network

(* set ~tls to false to get a plain-http server *)
let http_srv = http_server (conduit_direct ~tls:false stack)

let http_port =
  let doc = Key.Arg.info ~doc:"Listening HTTP port." ["http"] in
  Key.(create "http_port" Arg.(opt int 8080 doc))

let main =
  let packages =
    [
      package "uri";
      package "wodan";
      package "hex";
      package ~sublibs:["ocaml"] "checkseum";
    ]
  in
  let keys = List.map Key.abstract [http_port] in
  foreign ~packages ~keys "Dispatch.HTTP"
    (time @-> pclock @-> http @-> block @-> job)

let img = block_of_file "disk.img"

let () =
  register "http-server"
    [main $ default_time $ default_posix_clock $ http_srv $ img]
