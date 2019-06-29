module type PARAMS = sig
  val block_size : int

  val key_size : int
end

let pp_params fmt (module P : PARAMS) =
  Format.fprintf fmt "block_size: %d, key_size: %d" P.block_size P.key_size

type t = Cstruct.t

[@@@warning "-32"]

(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct
type superblock = {
  magic : uint8_t; [@len 16]
  (* major version, all later fields may change if this does *)
  version : uint32_t;
  compat_flags : uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags : uint32_t;
  block_size : uint32_t;
  key_size : uint8_t;
  first_block_written : uint64_t;
  logical_size : uint64_t;
  (* FSID is UUID-sized (128 bits) *)
  fsid : uint8_t; [@len 16]
  reserved : uint8_t; [@len 443]
  crc : uint32_t
}
[@@little_endian]]

[@@@warning "+32"]

let superblock_magic = "MIRAGE KVFS \xf0\x9f\x90\xaa"

let superblock_version = 1l

(* Incompatibility flags *)
let sb_incompat_rdepth = 1l

let sb_incompat_fsid = 2l

let sb_incompat_value_count = 4l

let sb_required_incompat =
  Int32.logor sb_incompat_rdepth
    (Int32.logor sb_incompat_fsid sb_incompat_value_count)

let () = assert (String.length superblock_magic = 16)

let () = assert (sizeof_superblock = 512)

let read_params sb =
  if copy_superblock_magic sb <> superblock_magic then `BadMagic
  else if get_superblock_version sb <> superblock_version then `BadVersion
  else if get_superblock_incompat_flags sb <> sb_required_incompat then
    `BadFlags
  else if not (Crc32c.cstruct_valid sb) then `BadCRC
  else
    let block_size = Int32.to_int (get_superblock_block_size sb) in
    let key_size = get_superblock_key_size sb in
    `Ok
      ( module struct
        let block_size = block_size

        let key_size = key_size
      end
      : PARAMS )

let pp_superblock_result pp_ok fmt = function
  | `Ok x ->
      pp_ok fmt x
  | `BadCRC ->
      Format.fprintf fmt "BadCRC"
  | `BadFlags ->
      Format.fprintf fmt "BadFlags"
  | `BadMagic ->
      Format.fprintf fmt "BadMagic"
  | `BadParams ->
      Format.fprintf fmt "BadParams"
  | `BadVersion ->
      Format.fprintf fmt "BadVersion"
  | `ReadError ->
      Format.fprintf fmt "ReadError"
  | `WriteError ->
      Format.fprintf fmt "WriteError"

let%expect_test "read_params" =
  let test steps =
    let cs = Cstruct.create sizeof_superblock in
    List.iter (fun f -> f cs) steps;
    let got = read_params cs in
    Format.printf "%a%!" (pp_superblock_result pp_params) got
  in
  let blit_string s cs off =
    Cstruct.blit_from_string s 0 cs off (String.length s)
  in
  let set_magic cs = blit_string "MIRAGE KVFS \xf0\x9f\x90\xaa" cs 0 in
  let set_version cs = blit_string "\x01\x00\x00\x00" cs 16 in
  let set_flags cs = blit_string "\x07\x00\x00\x00" cs 24 in
  let set_block_size cs = blit_string "\x78\x56\x34\x12" cs 28 in
  let set_key_size cs = blit_string "\x8f" cs 32 in
  let fix_crc cs = Crc32c.cstruct_reset cs in
  test [];
  [%expect {| BadMagic |}];
  test [set_magic];
  [%expect {| BadVersion |}];
  test [set_magic; set_version];
  [%expect {| BadFlags |}];
  test [set_magic; set_version; set_flags];
  [%expect {| BadCRC |}];
  test
    [set_magic; set_version; set_flags; set_block_size; set_key_size; fix_crc];
  [%expect {| block_size: 305419896, key_size: 143 |}]

type info = {
  first_block_written : int64;
  logical_size : int64;
  fsid : string
}

let read sb (module P : PARAMS) =
  if copy_superblock_magic sb <> superblock_magic then `BadMagic
  else if get_superblock_version sb <> superblock_version then `BadVersion
  else if get_superblock_incompat_flags sb <> sb_required_incompat then
    `BadFlags
  else if not (Crc32c.cstruct_valid sb) then `BadCRC
  else if get_superblock_block_size sb <> Int32.of_int P.block_size then (
    Logs.err (fun m ->
        m "Bad superblock size %ld %d"
          (get_superblock_block_size sb)
          P.block_size );
    `BadParams )
  else if get_superblock_key_size sb <> P.key_size then `BadParams
  else
    `Ok
      { first_block_written = get_superblock_first_block_written sb;
        logical_size = get_superblock_logical_size sb;
        fsid = Cstruct.to_string (get_superblock_fsid sb) }

let format sb (module P : PARAMS) {first_block_written; logical_size; fsid} =
  set_superblock_magic superblock_magic 0 sb;
  set_superblock_version sb superblock_version;
  set_superblock_incompat_flags sb sb_required_incompat;
  set_superblock_block_size sb (Int32.of_int P.block_size);
  set_superblock_key_size sb P.key_size;
  set_superblock_first_block_written sb first_block_written;
  set_superblock_logical_size sb logical_size;
  set_superblock_fsid fsid 0 sb;
  Crc32c.cstruct_reset sb

let allocate_block_io () =
  (* This will only work on Unix, which has buffered IO instead of direct IO.
        TODO figure out portability *)
  Cstruct.create sizeof_superblock

let read_from_disk ~read_disk =
  let open Lwt.Infix in
  let block_io = allocate_block_io () in
  read_disk block_io
  >|= function
  | Ok () ->
      `Ok block_io
  | Error _ ->
      `ReadError

let write_to_disk ~write_disk k =
  let open Lwt.Infix in
  let block_io = allocate_block_io () in
  k block_io;
  write_disk block_io
  >|= function
  | Ok () ->
      `Ok ()
  | Error _ ->
      `WriteError
