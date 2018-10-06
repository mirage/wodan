(* Copyright (c) 2016-2017, Gabriel de Perthuis - ISC licensed *)

let (~~~) = Int32.lognot

(* XXX x64 only *)
let optint_sign = Optint.of_int 0x8000_0000

let optint_of_uint32 i =
  if i < 0l then
    Optint.(logor optint_sign @@ of_int32 @@ Int32.neg i)
  else Optint.of_int32 i

let optint_to_uint32 i =
  Optint.to_int32 i


let cstruct ?(crc=0l) cstr =
  optint_to_uint32 @@ Checkseum.Crc32c.digest_bigstring (Cstruct.to_bigarray cstr) 0 (Cstruct.len cstr) (optint_of_uint32 crc)

let cstruct_valid str =
  ~~~(cstruct str) = 0l

(*$T cstruct_reset
let cstr = Cstruct.of_string "123456789...." in begin cstruct_reset cstr; cstruct_valid cstr end
*)
let cstruct_reset str =
  let sublen = (Cstruct.len str) - 4 in
  let crc = cstruct (Cstruct.sub str 0 sublen) in
  Cstruct.LE.set_uint32 str sublen ~~~crc

