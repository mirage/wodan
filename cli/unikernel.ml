open Mirage_types_lwt

module Client (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let restore _disk =
    let _csv = Csv.load_in stdin in
    Lwt.return_unit

  let dump disk =
    let%lwt root, _gen = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let out_csv = Csv.to_channel ~separator:'\t' stdout in
    Stor.search_range root (fun _k -> true) (fun _k -> false) (fun k v ->
      Csv.output_record out_csv [B64.encode @@ Stor.string_of_key k; B64.encode @@ Stor.string_of_value v]) >>
    begin Csv.close_out out_csv;
    Lwt.return_unit end
end
