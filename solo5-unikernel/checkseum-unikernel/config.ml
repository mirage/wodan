open Mirage

let stack = generic_stackv4 default_network
(* set ~tls to false to get a plain-http server *)
let http_srv = http_server @@ conduit_direct ~tls:false stack

let http_port =
  let doc = Key.Arg.info ~doc:"Listening HTTP port." ["http"] in
  Key.(create "http_port" Arg.(opt int 8080 doc))

let main =
  let packages = [
          package "uri";
          package ~sublibs:["c"] "checkseum";
  ] in
  let keys = List.map Key.abstract [ http_port ] in
  foreign
    ~packages ~keys
    "Dispatch.HTTP" (pclock @-> http @-> job)

let () =
  register "http" [main $ default_posix_clock $ http_srv]
