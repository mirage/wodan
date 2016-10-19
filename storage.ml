open Lwt.Infix

let superblock_magic = "kvqnsfmnlsvqfpge"
let superblock_version = 1l


exception BadMagic
exception BadVersion
exception BadFlags
exception ReadError
exception WriteError

(* 512 bytes *)
[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  (* must be all zeroes *)
  reserved: uint8_t [@len 476];
  crc: uint32_t;
}[@@little_endian]]

let () = assert (sizeof_superblock = 512)

module type PARAMS = sig
  val block_size: int32
end


module Make(B: V1_LWT.BLOCK)(P: PARAMS) = struct
  type filesystem = {
    disk: B.t;
    sb_io: Cstruct.t;
    sector_size: int;
  }

  (* 4096 with target=unix, 512 for virtualisation *)
  let prepare_io disk =
    B.get_info disk >>= fun info ->
    Lwt.return {
      disk;
      sector_size = info.B.sector_size;
      sb_io = Cstruct.sub Io_page.(to_cstruct @@ get 1) 0 info.B.sector_size;
    }

  let read_superblock fs =
    B.read fs.disk 0L [ fs.sb_io ] >>= function
      |`Error _ -> Lwt.fail ReadError
      |`Ok () ->
      if Cstruct.to_string @@ get_superblock_magic fs.sb_io != superblock_magic
      then Lwt.fail BadMagic
      else if get_superblock_version fs.sb_io != superblock_version
      then Lwt.fail BadVersion
      else if get_superblock_incompat_flags fs.sb_io != 0l
      then Lwt.fail BadFlags
      else Lwt.return ()

  let format fs = (* just the superblock for now *)
    let () = set_superblock_magic superblock_magic 0 fs.sb_io in
    let () = set_superblock_version fs.sb_io superblock_version in
    let () = set_superblock_block_size fs.sb_io P.block_size in
    B.write fs.disk 0L [ fs.sb_io ] >>= function
      |`Ok () -> Lwt.return ()
      |`Error _ -> Lwt.fail WriteError

  let write_block = failwith "write_block"
end

