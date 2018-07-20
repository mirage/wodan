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

module Client (C: CONSOLE) (B: Wodan.EXTBLOCK) = struct
  module Stor = Wodan.Make(B)(struct include Wodan.StandardParams (*let block_size=512*) end)

  let start _con disk _crypto =
    let ios = ref 0 in
    let time0 = ref 0. in
    let%lwt info = B.get_info disk in
    (*Logs.info (fun m ->
        m "Sectors %Ld %d" info.size_sectors info.sector_size);*)
    let%lwt rootval, _gen0 = Stor.prepare_io (Wodan.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Stor.P.block_size)) disk 1024 in
    (
    let root = ref rootval in
    let key = Stor.key_of_cstruct @@ Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Stor.value_of_cstruct @@ Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>= fun () ->
    Stor.flush !root >>= function gen1 ->
    let%lwt Some cval1 = Stor.lookup !root key in
    (*Cstruct.hexdump cval1;*)
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval1));
    let%lwt rootval, gen2 = Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
    root := rootval;
    let%lwt Some cval2 = Stor.lookup !root key in
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval2));
    if gen1 <> gen2 then begin Logs.err (fun m -> m "Generation fail %Ld %Ld" gen1 gen2); assert false; end;
    time0 := Unix.gettimeofday ();
    while%lwt true do
      let key = Stor.key_of_cstruct @@ Nocrypto.Rng.generate 20 and
        cval = Stor.value_of_cstruct @@ Nocrypto.Rng.generate 40 in
      begin try%lwt
        ios := succ !ios;
        Stor.insert !root key cval
      with
      |Wodan.NeedsFlush -> begin
        Logs.info (fun m -> m "Emergency flushing");
        Stor.flush !root >>= function _gen ->
        Stor.insert !root key cval
      end
      |Wodan.OutOfSpace as e -> begin
        Logs.info (fun m -> m "Final flush");
        Stor.flush !root >|= ignore >>= fun () ->
        raise e
      end
      end
      >>= fun () ->
      if%lwt Lwt.return (Nocrypto.Rng.Int.gen 16384 = 0) then begin (* Infrequent re-opening *)
        Stor.flush !root >>= function gen3 ->
        let%lwt rootval, gen4 = Stor.prepare_io Wodan.OpenExistingDevice disk 1024 in
        root := rootval;
        assert (gen3 = gen4);
        Lwt.return ()
      end
      else if%lwt Lwt.return (false && Nocrypto.Rng.Int.gen 8192 = 0) then begin (* Infrequent flushing *)
        Stor.log_statistics !root;
        Stor.flush !root >|= ignore
      end done
      )
      [%lwt.finally begin
        let time1 = Unix.gettimeofday () in
        let iops = (float_of_int !ios) /. (time1 -. !time0) in
        (*Stor.log_statistics root;*)
        Logs.info (fun m -> m "IOPS %f" iops);
        Lwt.return_unit
      end]
end
