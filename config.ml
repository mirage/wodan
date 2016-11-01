open Mirage

let client =
  let packages = [ "mirage-logs"; "nocrypto"; "io-page"; "lru-cache"; ] in
  let libraries = [ "mirage-logs"; "nocrypto"; "io-page"; "lwt.ppx"; "lru-cache"; ] in
  foreign
    ~libraries ~packages
    ~deps:[abstract nocrypto]
    "Unikernel.Client" @@ console @-> block @-> job

let () =
  let img = block_of_file "disk.img" in
  let job =  [ client $ default_console $ img ] in
  register "storage" job
