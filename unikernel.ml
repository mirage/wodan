open Lwt.Infix
open V1_LWT

module Client (C: CONSOLE) (B: BLOCK) = struct
  let start con disk =
    let module Stor = Storage.Make(B)(Storage.StandardParams) in
    let%lwt fs = Stor.prepare_io Storage.FormatEmptyDevice disk in
    let%lwt fs1 = Stor.prepare_io Storage.OpenExistingDevice disk in
    Lwt.return ()
end
