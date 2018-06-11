(*************************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                          *)
(*                                                                                   *)
(*  Permission to use, copy, modify, and/or distribute this software for any         *)
(*  purpose with or without fee is hereby granted, provided that the above           *)
(*  copyright notice and this permission notice appear in all copies.                *)
(*                                                                                   *)
(*  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH    *)
(*  REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND  *)
(*  FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,         *)
(*  INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM      *)
(*  LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR    *)
(*  OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR           *)
(*  PERFORMANCE OF THIS SOFTWARE.                                                    *)
(*                                                                                   *)
(*************************************************************************************)

open Mirage_types_lwt
open Lwt.Infix

let magiccrc = Cstruct.of_string "\xff\xff\xff\xff"

let cstr_cond_reset str =
  let crcoffset = (Cstruct.len str) - 4 in
  let crc = Cstruct.sub str crcoffset 4 in
  if Cstruct.equal crc magiccrc then
  Crc32c.cstruct_reset str

module Client (C: CONSOLE) (B: Wodan.EXTBLOCK) = struct
module Stor = Storage.Make(B)(struct
  include Storage.StandardParams
  let block_size = 512
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
    done >>= fun () ->
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let root = ref @@ Storage.RootMap.find 1l roots in
    let key = Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>= fun () ->
    Stor.flush !root.open_fs >>= fun () ->
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
