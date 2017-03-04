open Mirage

let client =
  let packages = [ package "mirage-logs"; package "nocrypto"; package "io-page"; package "lru-cache"; package "bitv"; ] in
  foreign
    ~packages
    ~deps:[abstract nocrypto]
    "Unikernel.Client" @@ console @-> block @-> job

let () =
  let img = generic_block "disk.img" in
  let job = [ client $ default_console $ img ] in
  register "storage" job
