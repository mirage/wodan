open Mirage_types_lwt

module Client (C: CONSOLE) (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let start _con disk _crypto =
    let%lwt info = B.get_info disk in
    let%lwt roots = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    (*let%lwt roots1 = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in*)
    let root = Storage.RootMap.find 1l roots in
    (
    let key = Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    let () = Stor.insert root key cval in
    let%lwt () = Stor.flush root.open_fs in
    let%lwt cval1 = Stor.lookup root key in
    (*let () = Cstruct.hexdump cval1 in*)
    let () = assert (Cstruct.equal cval cval1) in
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let root = Storage.RootMap.find 1l roots in
    let%lwt cval2 = Stor.lookup root key in
    let () = assert (Cstruct.equal cval cval2) in
    while true do
      let key = Nocrypto.Rng.generate 20 and
        cval = Nocrypto.Rng.generate 40 in
      Stor.insert root key cval
    done;
    Lwt.return ()
    )
      [%lwt.finally Lwt.return @@ Stor.log_statistics root]
end
