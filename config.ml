open Mirage

let client =
  let packages = [ "io-page"; "lru-cache"; ] in
  let libraries = [ "io-page"; "lwt.ppx"; "lru-cache"; ] in
  foreign
    ~libraries ~packages
    "Unikernel.Client" @@ console @-> block @-> job

let () =
  let img = block_of_file "disk.img" in
  let job =  [ client $ default_console $ img ] in
  register "storage" job
