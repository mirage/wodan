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

let unwrap_opt = function
|None -> failwith "Expected Some"
|Some x -> x

module Client (B: Wodan.EXTBLOCK) = struct
  let trim disk =
    Wodan.open_for_reading (module B) disk Wodan.standard_mount_options
    >>= function (Wodan.OPEN_RET ((module Stor), root, _gen)) ->
    Stor.fstrim root

  let format disk =
    let module Stor = Wodan.Make(B)(Wodan.StandardSuperblockParams) in
    let%lwt info = B.get_info disk in
    let%lwt _root, _gen = Stor.prepare_io (Wodan.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Wodan.StandardSuperblockParams.block_size)) disk Wodan.standard_mount_options in
    Lwt.return_unit

  let restore disk =
    Wodan.open_for_reading (module B) disk Wodan.standard_mount_options
    >>= function (Wodan.OPEN_RET ((module Stor), root, _gen)) ->
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
    Wodan.open_for_reading (module B) disk Wodan.standard_mount_options
    >>= function (Wodan.OPEN_RET ((module Stor), root, _gen)) ->
    let out_csv = Csv.to_channel ~separator:'\t' stdout in
    Stor.iter root (fun k v ->
      Csv.output_record out_csv [B64.encode @@ Stor.string_of_key k; B64.encode @@ Stor.string_of_value v]) >>= fun () ->
    begin Csv.close_out out_csv;
    Lwt.return_unit end

  let exercise disk block_size =
    let bs = match block_size with
      |None -> Wodan.StandardSuperblockParams.block_size
      |Some block_size -> block_size
    in
    let module Stor = Wodan.Make(B)(struct
        include Wodan.StandardSuperblockParams
        let block_size = bs
      end) in

    let ios = ref 0 in
    let time0 = ref 0. in
    let%lwt info = B.get_info disk in
    (*Logs.info (fun m ->
        m "Sectors %Ld %d" info.size_sectors info.sector_size);*)
    let%lwt rootval, _gen0 = Stor.prepare_io (Wodan.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Stor.P.block_size)) disk Wodan.standard_mount_options in
    (
    let root = ref rootval in
    let key = Stor.key_of_cstruct @@ Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Stor.value_of_cstruct @@ Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>= fun () ->
    Stor.flush !root >>= function gen1 ->
    Stor.lookup !root key >>= function cval1_opt ->
    let cval1 = unwrap_opt cval1_opt in
    (*Cstruct.hexdump cval1;*)
    assert (Cstruct.equal (Stor.cstruct_of_value cval) (Stor.cstruct_of_value cval1));
    let%lwt rootval, gen2 = Stor.prepare_io Wodan.OpenExistingDevice disk Wodan.standard_mount_options in
    root := rootval;
    Stor.lookup !root key >>= function cval2_opt ->
    let cval2 = unwrap_opt cval2_opt in
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
        let%lwt rootval, gen4 = Stor.prepare_io Wodan.OpenExistingDevice disk Wodan.standard_mount_options in
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

  let fuzz disk =
    Wodan.read_superblock_params (module B) disk >>= function sb_params ->
      let module Stor = Wodan.Make(B)(val sb_params) in

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
    Stor.prepare_io Wodan.OpenExistingDevice disk Wodan.standard_mount_options in
    let key = Stor.key_of_string "abcdefghijklmnopqrst" in
    let cval = Stor.value_of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert root key cval >>= fun () ->
    Stor.flush root >>= fun _gen ->
    let%lwt cval1 = Stor.lookup root key >|= unwrap_opt in
    assert (Cstruct.equal
      (Stor.cstruct_of_value cval)
      (Stor.cstruct_of_value cval1));
    let%lwt root, _rgen =
      Stor.prepare_io Wodan.OpenExistingDevice disk Wodan.standard_mount_options in
    let%lwt cval2 = Stor.lookup root key >|= unwrap_opt in
    assert (Cstruct.equal
      (Stor.cstruct_of_value cval)
      (Stor.cstruct_of_value cval2));
    Lwt.return ()
end
