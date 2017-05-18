open Mirage_types_lwt
open Lwt.Infix

module Client (C: CONSOLE) (B: BLOCK) = struct
module Stor = Storage.Make(B)(struct
  include Storage.StandardParams
  let block_size = 4096
end)

  let start _con disk _crypto =
  let f () =
    let%lwt info = B.get_info disk in
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let root = ref @@ Storage.RootMap.find 1l roots in
    let key = Cstruct.of_string "abcdefghijklmnopqrst" in
    let cval = Cstruct.of_string "sqnlnfdvulnqsvfjlllsvqoiuuoezr" in
    Stor.insert !root key cval >>
    Stor.flush !root.open_fs >>
    let%lwt cval1 = Stor.lookup !root key in
    assert (Cstruct.equal cval cval1);
    let%lwt roots = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    root := Storage.RootMap.find 1l roots;
    let%lwt cval2 = Stor.lookup !root key in
    assert (Cstruct.equal cval cval2);
    Lwt.return ()
  in
  let f2 () =
    Lwt_main.run (f ())
  in
    AflPersistent.run f2;
    Lwt.return ()
end
