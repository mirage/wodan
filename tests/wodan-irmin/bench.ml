module BlockCon = struct
  include Ramdisk

  let devices = Hashtbl.create 1

  (* This is Ramdisk.connect but with a different default size *)
  let connect name =
    if Hashtbl.mem devices name then Lwt.return (Hashtbl.find devices name)
    else
      Lwt.bind (create ~name ~size_sectors:131072L ~sector_size:512)
        (fun device ->
          let device = Result.get_ok device in
          Hashtbl.replace devices name device;
          Lwt.return device)

  let discard _ _ _ = Lwt.return (Ok ())
end

module DB_ram =
  Wodan_irmin.DB_BUILDER (BlockCon) (Wodan_irmin.StandardSuperblockParams)
module KV_chunked =
  Wodan_irmin.KV_chunked (DB_ram) (Irmin.Hash.SHA1) (Irmin.Contents.String)
module Bench = Irmin_bench.Make (KV_chunked)

let config ~root:_ = Wodan_irmin.config ~path:"disk.img" ~create:true ()

let size ~root:_ = 0

let () = Lwt_main.run (Nocrypto_entropy_lwt.initialize ())

let () = Bench.run ~config ~size
