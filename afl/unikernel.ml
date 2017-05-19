open Mirage_types_lwt
open Lwt.Infix

let magiccrc = Cstruct.of_string "\xff\xff\xff\xff"

let cstr_cond_reset str =
  let crcoffset = (Cstruct.len str) - 4 in
  let crc = Cstruct.sub str crcoffset 4 in
  if Cstruct.equal crc magiccrc then
  Crc32c.cstruct_reset str

module Client (C: CONSOLE) (B: BLOCK) = struct
module Stor = Storage.Make(B)(struct
  include Storage.StandardParams
  let block_size = 4096
end)

  let start _con disk _crypto =
  let f () =
    let cstr = Stor._get_block_io () in
    let%lwt res = B.read disk (Int64.of_int Stor.P.block_size) [cstr] in
    cstr_cond_reset @@ Cstruct.sub cstr 0 Storage.sizeof_superblock;
    let%lwt info = B.get_info disk in
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let root = ref @@ Storage.RootMap.find 1l roots in
    let key = Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>
    Stor.flush !root.open_fs >>
    let%lwt cval1 = Stor.lookup !root key in
    assert (Cstruct.equal cval cval1);
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    root := Storage.RootMap.find 1l roots;
    let%lwt cval2 = Stor.lookup !root key in
    assert (Cstruct.equal cval cval2);
    Lwt.return ()
  in
  let f2 () =
    Lwt_main.run (f ())
  in
    AflPersistent.run f2;
    Lwt.return ()
end
