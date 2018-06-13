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

open Lwt.Infix

module Client (B: Wodan.EXTBLOCK) = struct
  module Stor = Wodan.Make(B)(Wodan.StandardParams)

  let trim disk =
    let%lwt root, _gen = Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
    Stor.fstrim root

  let format disk =
    let%lwt info = B.get_info disk in
    let%lwt _root, _gen = Stor.prepare_io (Wodan.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Wodan.StandardParams.block_size)) disk 1024 in
    Lwt.return_unit

  let restore disk =
    let%lwt root, _gen = Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
    let csv_in = Csv.of_channel ~separator:'\t' stdin in
    let compl = ref [] in
    Csv.iter ~f:(fun l ->
      match l with
      |[k; v] ->
      compl := ( try%lwt Stor.insert root (Stor.key_of_string @@ B64.decode k) (Stor.value_of_string @@ B64.decode v) with Wodan.NeedsFlush -> let%lwt _gen = Stor.flush root in Lwt.return_unit ) :: !compl
      |_ -> failwith "Bad CSV format"
      ) csv_in;
    Lwt.join !compl >>= fun () ->
    let%lwt _gen = Stor.flush root in
    Lwt.return_unit

  let dump disk =
    let%lwt root, _gen = Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
    let out_csv = Csv.to_channel ~separator:'\t' stdout in
    Stor.search_range root (fun _k -> true) (fun _k -> false) (fun k v ->
      Csv.output_record out_csv [B64.encode @@ Stor.string_of_key k; B64.encode @@ Stor.string_of_value v]) >>= fun () ->
    begin Csv.close_out out_csv;
    Lwt.return_unit end

  let fuzz disk =
    let module Stor = Wodan.Make(B)(struct
      include Wodan.StandardParams
      let block_size = 512
    end) in

    assert (Stor.P.block_size = 512);
    let magiccrc = Cstruct.of_string "\xff\xff\xff\xff" in

    let cstr_cond_reset str =
      let crcoffset = (Cstruct.len str) - 4 in
      let crc = Cstruct.sub str crcoffset 4 in
      if Cstruct.equal crc magiccrc then begin
        Crc32c.cstruct_reset str;
        true
      end else
        false
    in

    let%lwt info = B.get_info disk in
    let logical_size = Int64.(to_int @@ div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Stor.P.block_size) in
    let cstr = Cstruct.create Stor.P.block_size in
    let%lwt _res = B.read disk 0L [cstr] in
    if%lwt Lwt.return @@ cstr_cond_reset @@ Cstruct.sub cstr 0 Wodan.sizeof_superblock then
      B.write disk 0L [cstr] >|= ignore
    >>= fun _ ->
    for%lwt i = 1 to logical_size - 1 do
      let doffset = Int64.(mul (of_int i) @@ of_int Stor.P.block_size) in
      let%lwt _res = B.read disk doffset [cstr] in
      if%lwt Lwt.return @@ cstr_cond_reset cstr then
        B.write disk doffset [cstr]
      >|= ignore
    done >>= fun _ ->
    let%lwt root, _rgen =
    Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
    let key = Stor.key_of_string "abcdefghijklmnopqrst" in
    let cval = Stor.value_of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert root key cval >>= fun () ->
    Stor.flush root >>= fun _gen ->
    let%lwt Some cval1 = Stor.lookup root key in
    assert (Cstruct.equal
      (Stor.cstruct_of_value cval)
      (Stor.cstruct_of_value cval1));
    let%lwt root, _rgen =
      Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
    let%lwt Some cval2 = Stor.lookup root key in
    assert (Cstruct.equal
      (Stor.cstruct_of_value cval)
      (Stor.cstruct_of_value cval2));
    Lwt.return ()
end
