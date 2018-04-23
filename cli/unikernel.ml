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

module Client (B: BLOCK) = struct
  module Stor = Wodan.Make(B)(Wodan.StandardParams)

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
end
