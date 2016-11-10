open V1_LWT

module Client (C: CONSOLE) (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let start _con disk _crypto =
    let%lwt info = B.get_info disk in
    let%lwt roots = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.B.size_sectors @@ of_int info.B.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    (*let%lwt roots1 = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in*)
    let root = Storage.RootMap.find 1l roots in
    let key = Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    let () = Stor.insert root key cval in
    let%lwt cval1 = Stor.lookup root key in
    (*let () = Cstruct.hexdump cval1 in*)
    let () = assert (Cstruct.equal cval cval1) in
    Lwt.return ()
end
