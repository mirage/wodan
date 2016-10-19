open Lwt.Infix

let superblock_magic = "kvqnsfmnlsvqfpge"
let superblock_version = 1l


exception BadMagic
exception BadVersion
exception BadFlags
exception BadCRC
exception ReadError
exception WriteError

(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version, all later fields may change if this does *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  reserved: uint8_t [@len 476];
  crc: uint32_t;
}[@@little_endian]]

let () = assert (sizeof_superblock = 512)

let rec make_fanned_io_list size cstr =
  if Cstruct.len cstr = 0 then []
  else let head, rest = Cstruct.split cstr size in
  head::make_fanned_io_list size rest

module type PARAMS = sig
  val block_size: int
end

module StandardParams = struct
  let block_size = 65536
end

type deviceOpenMode = OpenExistingDevice|FormatEmptyDevice


module Make(B: V1_LWT.BLOCK)(P: PARAMS) = struct
  type filesystem = {
    (* Backing device *)
    disk: B.t;
    (* The exact size of IO the BLOCK accepts.
     * Even larger powers of two won't work *)
    (* 4096 with target=unix, 512 with virtualisation *)
    sector_size: int;
    (* IO on an erase block *)
    block_io: Cstruct.t;
    (* A view on block_io split as sector_size sized views *)
    block_io_fanned: Cstruct.t list;
  }

  let _sb_io block_io =
    Cstruct.sub block_io 0 sizeof_superblock

  let _read_superblock fs =
    B.read fs.disk 0L fs.block_io_fanned >>= function
      |`Error _ -> Lwt.fail ReadError
      |`Ok () ->
          let sb = _sb_io fs.block_io in
      if Cstruct.to_string @@ get_superblock_magic sb <> superblock_magic
      then Lwt.fail BadMagic
      else if get_superblock_version sb <> superblock_version
      then Lwt.fail BadVersion
      else if get_superblock_incompat_flags sb <> 0l
      then Lwt.fail BadFlags
      else if not @@ Crc32c.cstruct_valid sb
      then Lwt.fail BadCRC
      else Lwt.return ()

  (* Just the superblock for now.
   * Requires the caller to discard the entire device first.
   * Don't add call sites beyond prepare_io, the io pages must be zeroed *)
  let _format fs =
    let sb = _sb_io fs.block_io in
    let () = set_superblock_magic superblock_magic 0 sb in
    let () = set_superblock_version sb superblock_version in
    let () = set_superblock_block_size sb (Int32.of_int P.block_size) in
    let () = Crc32c.cstruct_reset sb in
    B.write fs.disk 0L fs.block_io_fanned >>= function
      |`Ok () -> Lwt.return ()
      |`Error _ -> Lwt.fail WriteError

  let prepare_io mode disk =
    B.get_info disk >>= fun info ->
      let sector_size = info.B.sector_size in
      let block_size = P.block_size in
      let page_size = Io_page.page_size in
      let () = assert (block_size >= page_size) in
      let () = assert (page_size >= sector_size) in
      let () = assert (block_size mod page_size = 0) in
      let () = assert (page_size mod sector_size = 0) in
      let block_io = Io_page.get_buf ~n:(block_size/page_size) () in
      let fs = {
        disk;
        sector_size;
        block_io;
        block_io_fanned = make_fanned_io_list sector_size block_io;
      } in match mode with
        |OpenExistingDevice -> let%lwt () = _read_superblock fs in Lwt.return fs
        |FormatEmptyDevice -> let%lwt () = _format fs in Lwt.return fs

  let write_block fs logical = failwith "write_block"

  let read_block fs logical = failwith "read_block"

  let find_newest_root fs = failwith "find_newest_root"
end

