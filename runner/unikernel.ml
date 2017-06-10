open Mirage_types_lwt
open Lwt.Infix

module Client (C: CONSOLE) (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let start _con disk _crypto =
    let%lwt info = B.get_info disk in
    let%lwt root = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    (
    let key = Stor.key_of_cstruct @@ Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Stor.value_of_cstruct @@ Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert root key cval >>
    Stor.flush root >>= function _generation ->
    let%lwt cval1 = Stor.lookup root key in
    (*Cstruct.hexdump cval1;*)
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval1));
    let%lwt root = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let%lwt cval2 = Stor.lookup root key in
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval2));
    while%lwt true do
      let key = Stor.key_of_cstruct @@ Nocrypto.Rng.generate 20 and
        cval = Stor.value_of_cstruct @@ Nocrypto.Rng.generate 40 in
      try%lwt
        Stor.insert root key cval
      with Storage.NeedsFlush -> begin
        Logs.info (fun m -> m "Emergency flushing");
        Stor.flush root >>= function _generation ->
        Stor.insert root key cval
      end
      >>= function () ->
      if%lwt Lwt.return (Nocrypto.Rng.Int.gen 16384 = 0) then begin (* Infrequent re-opening *)
        Stor.flush root >>= function _generation ->
        let%lwt root = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
        Lwt.return ()
      end
      else if%lwt Lwt.return (Nocrypto.Rng.Int.gen 8192 = 0) then begin (* Infrequent flushing *)
        Stor.log_statistics root;
        Stor.flush root >|= ignore
      end done
    )
      [%lwt.finally Lwt.return @@ Stor.log_statistics root]
end
