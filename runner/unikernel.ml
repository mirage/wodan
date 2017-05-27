open Mirage_types_lwt
open Lwt.Infix

module Client (C: CONSOLE) (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let start _con disk _crypto =
    let%lwt info = B.get_info disk in
    let%lwt roots = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    (*let%lwt roots1 = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in*)
    let root = ref @@ Storage.RootMap.find 1l roots in
    (
    let key = Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>
    Stor.flush !root.open_fs >>
    let%lwt cval1 = Stor.lookup !root key in
    (*Cstruct.hexdump cval1;*)
    assert (Cstruct.equal cval cval1);
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    root := Storage.RootMap.find 1l roots;
    let%lwt cval2 = Stor.lookup !root key in
    assert (Cstruct.equal cval cval2);
    while%lwt true do
      let key = Nocrypto.Rng.generate 20 and
        cval = Nocrypto.Rng.generate 40 in
      try%lwt
        Stor.insert !root key cval
      with Storage.NeedsFlush -> begin
        Logs.info (fun m -> m "Emergency flushing");
        Stor.flush !root.open_fs >>= function () ->
        Stor.insert !root key cval
      end
      >>= function () ->
      if%lwt Lwt.return (Nocrypto.Rng.Int.gen 16384 = 0) then begin (* Infrequent re-opening *)
        Stor.flush !root.open_fs >>
        let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
        root := Storage.RootMap.find 1l roots;
        Lwt.return ()
      end
      else if%lwt Lwt.return (Nocrypto.Rng.Int.gen 8192 = 0) then begin (* Infrequent flushing *)
        Stor.log_statistics !root;
        Stor.flush !root.open_fs
      end done
    )
      [%lwt.finally Lwt.return @@ Stor.log_statistics !root]
end
