(* Copyright 2014 Citrix - ISC licensed *)

val cstruct: ?crc:int32 -> Cstruct.t -> int32
(** [cstruct ?crc buf] computes the CRC32C of [buf] with optional
    initial value [crc] *)

val string: ?crc:int32 -> string -> int -> int -> int32
(** [string ?crc buf ofs len] computes the CRC32C of the substring
    of length [len] starting at offset [ofs] in string [buf] with
    optional initial value [crc] *)

val cstruct_valid: Cstruct.t -> bool
(** [cstruct_valid cstruct] returns whether the CRC32C of cstruct is
    0xffffffffl *)

val cstruct_reset: Cstruct.t -> unit
(** [cstruct_reset cstruct] rewrites the last four bytes of
    cstruct so that [cstruct_valid cstruct] is true *)

