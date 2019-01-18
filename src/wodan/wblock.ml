(*************************************************************************************)
(*  Copyright 2017 Gabriel de Perthuis <g2p.code@gmail.com>                          *)
(*  Copyright 2019 Nicolas Assouad <nicolas@tarides.com>                          *)
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

exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC of int64
exception BadParams
exception ReadError


(* All parameters that can be read from the superblock *)
module type SUPERBLOCK_PARAMS = sig
  (* Size of blocks, in bytes *)
  val block_size: int
  (* The exact size of all keys, in bytes *)
  val key_size: int
end

module StandardSuperblockParams : SUPERBLOCK_PARAMS = struct
  let block_size = 256*1024
  let key_size = 20
end

let superblock_magic = "MIRAGE KVFS \xf0\x9f\x90\xaa"
let () = assert (String.length superblock_magic = 16)

let superblock_version = 1l

(* Incompatibility flags *)
let sb_incompat_rdepth = 1l
let sb_incompat_fsid = 2l
let sb_incompat_value_count = 4l
let sb_required_incompat = Int32.logor sb_incompat_rdepth
  @@ Int32.logor sb_incompat_fsid sb_incompat_value_count

let sizeof_datalen = 2

let sizeof_logical = 8

let sizeof_crc = 4

[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version, all later fields may change if this does *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  key_size: uint8_t;
  first_block_written: uint64_t;
  logical_size: uint64_t;
  (* FSID is UUID-sized (128 bits) *)
  fsid: uint8_t [@len 16];
  reserved: uint8_t [@len 443];
  crc: uint32_t;
}[@@little_endian]]

let () = assert (sizeof_superblock = 512)

[%%cstruct type anynode_hdr = {
  nodetype: uint8_t;
  generation: uint64_t;
  fsid: uint8_t [@len 16];
  value_count: uint32_t;
}[@@little_endian]]
let () = assert (sizeof_anynode_hdr = 29)

[%%cstruct type rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype: uint8_t;
  (* will this wrap? there's no uint128_t. Nah, flash will wear out first. *)
  generation: uint64_t;
  fsid: uint8_t [@len 16];
  value_count: uint32_t;
  depth: uint32_t;
}[@@little_endian]]
let () = assert (sizeof_rootnode_hdr = 33)
(* Contents: logged data, and child node links *)
(* All node types end with a CRC *)
(* rootnode_hdr
 * logged data: (key, datalen, data)*, grow from the left end towards the right
 *
 * child links: (key, logical offset)*, grow from the right end towards the left
 * crc *)

[%%cstruct type childnode_hdr = {
  (* nodetype = 2 *)
  nodetype: uint8_t;
  generation: uint64_t;
  fsid: uint8_t [@len 16];
  value_count: uint32_t;
}[@@little_endian]]
let () = assert (sizeof_childnode_hdr = 29)
(* Contents: logged data, and child node links *)
(* Layout: see above *)

let _sb_io block_io =
  Cstruct.sub block_io 0 sizeof_superblock

let _get_superblock_io () =
  (* This will only work on Unix, which has buffered IO instead of direct IO.
  TODO figure out portability *)
    Cstruct.create 512

let read_superblock_params (type disk) (module B: Mirage_types_lwt.BLOCK with type t = disk) disk =
  let block_io = _get_superblock_io () in
  let block_io_fanned = [block_io] in
  B.read disk 0L block_io_fanned >>= Lwt.wrap1 begin function
    |Result.Error _ -> raise ReadError
    |Result.Ok () ->
        let sb = _sb_io block_io in
    if copy_superblock_magic sb <> superblock_magic
    then raise BadMagic
    else if get_superblock_version sb <> superblock_version
    then raise BadVersion
    else if get_superblock_incompat_flags sb <> sb_required_incompat
    then raise BadFlags
    else if not @@ Wodan_crc32c.cstruct_valid sb
    then raise @@ BadCRC 0L
    else begin
      let block_size = Int32.to_int @@ get_superblock_block_size sb in
      let key_size = get_superblock_key_size sb in
      (module struct
        let block_size = block_size
        let key_size = key_size
      end : SUPERBLOCK_PARAMS)
    end
  end
