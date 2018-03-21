include Lwt.Infix

(*module BC = struct
  include Block
end*)
module BC = struct
  include Ramdisk
  let connect name = Ramdisk.connect ~name
end

module S = Irmin_wodan.KV(BC)(Irmin_wodan.StandardParams)(Irmin.Contents.String)
module Sync = Irmin.Sync(S)
let config = Irmin_wodan.config ~path:"disk.img" ~create:true ()

let upstream = Irmin.remote_uri "git://github.com/g2p/wodan.git"

let test () =
  Nocrypto_entropy_lwt.initialize ()
  >>= fun _nc -> S.Repo.v config
  >>= S.master
  >>= fun t  -> Sync.pull_exn t upstream `Set
  >>= fun () -> S.get t ["README.md"]
  >|= fun r  -> Printf.printf "%s\n%!" r

let () =
  Lwt_main.run @@ test ()

