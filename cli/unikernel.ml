open Mirage_types_lwt

module Client (B: BLOCK) = struct
  module Stor = Storage.Make(B)(Storage.StandardParams)

  let format disk =
    let%lwt info = B.get_info disk in
    let%lwt _root, _gen = Stor.prepare_io (Storage.FormatEmptyDevice
      Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)) disk 1024 in
    Lwt.return_unit

  let restore disk =
    let%lwt root, _gen = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let csv_in = Csv.of_channel ~separator:'\t' stdin in
    let compl = ref [] in
    Csv.iter ~f:(fun l ->
      match l with
      |[k; v] ->
      compl := ( try%lwt Stor.insert root (Stor.key_of_string @@ B64.decode k) (Stor.value_of_string @@ B64.decode v) with Storage.NeedsFlush -> let%lwt _gen = Stor.flush root in Lwt.return_unit ) :: !compl
      |_ -> failwith "Bad CSV format"
      ) csv_in;
    Lwt.join !compl >>
    let%lwt _gen = Stor.flush root in
    Lwt.return_unit

  let dump disk =
    let%lwt root, _gen = Stor.prepare_io Storage.OpenExistingDevice disk 1024 in
    let out_csv = Csv.to_channel ~separator:'\t' stdout in
    Stor.search_range root (fun _k -> true) (fun _k -> false) (fun k v ->
      Csv.output_record out_csv [B64.encode @@ Stor.string_of_key k; B64.encode @@ Stor.string_of_value v]) >>
    begin Csv.close_out out_csv;
    Lwt.return_unit end
end
