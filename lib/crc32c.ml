(* Copyright (c) 2016-2017, Gabriel de Perthuis - ISC licensed *)

let (~~~) = Int32.lognot

let cstruct ?(crc=0l) cstr =
  Optint.to_int32 @@ Checkseum.Adler32.digest_bigstring (Cstruct.to_bigarray cstr) 0 (Cstruct.len cstr) (Optint.of_int32 crc)

let cstruct_valid str =
  ~~~(cstruct str) = 0l

(*$T cstruct_reset
let cstr = Cstruct.of_string "123456789...." in begin cstruct_reset cstr; cstruct_valid cstr end
*)
let cstruct_reset str =
  let sublen = (Cstruct.len str) - 4 in
  let crc = cstruct (Cstruct.sub str 0 sublen) in
  Cstruct.LE.set_uint32 str sublen ~~~crc

