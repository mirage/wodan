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
(* Can't go smaller than Io_page.page_size, at least using this direct io friendly setup *)
  let block_size = 4096
end)

  let start _con disk _crypto =
  let f () =
    let%lwt info = B.get_info disk in
    let logical_size = Int64.(to_int @@ div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Stor.P.block_size) in
    let cstr = Stor._get_block_io () in
    let%lwt res = B.read disk 0L [cstr] in
    cstr_cond_reset @@ Cstruct.sub cstr 0 Storage.sizeof_superblock;
    for%lwt i = 1 to logical_size - 1 do
      let%lwt res = B.read disk Int64.(mul (of_int i) @@ of_int Stor.P.block_size) [cstr] in
      cstr_cond_reset cstr;
      Lwt.return ()
    done >>
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
    if false then begin
      AflPersistent.run f2;
      Lwt.return ()
    end else
      f ()
end
