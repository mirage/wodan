open V1_LWT

module Client (C: CONSOLE) (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let start _con disk _crypto =
    let%lwt info = B.get_info disk in
    let%lwt _fs = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.B.size_sectors @@ of_int info.B.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    let%lwt _fs1 = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    Lwt.return ()
end
