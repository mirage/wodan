open Stdcompat

module type OrderedType = sig
  type t

  val compare : t -> t -> int
end

module Make (Ord : OrderedType) = struct
  exception Already_exists

  module M = Map.Make (Ord)

  type 'a t = 'a M.t ref

  type key = Ord.t

  let create () = ref M.empty

  let length m = M.cardinal !m

  let clear m = m := M.empty

  let is_empty m = !m = M.empty

  let find m k = M.find k !m

  let find_opt m k = M.find_opt k !m

  let mem m k = M.mem k !m

  let add m k v = m := M.add k v !m

  let update m k f = m := M.update k f !m

  let replace_existing m k v =
    m :=
      M.update k
        (function
          | Some _ ->
              Some v
          | None ->
              raise Not_found )
        !m

  let xadd m k v =
    m :=
      M.update k
        (function
          | Some _ ->
              raise Already_exists
          | None ->
              Some v )
        !m

  let remove m k = m := M.remove k !m

  let iter f m = M.iter f !m

  let iter_range f m start end_excl =
    try
      M.to_seq_from start !m
      |> Seq.iter (fun (k, v) ->
             if Ord.compare k end_excl < 0 then f k v else raise Exit )
    with Exit -> ()

  let iter_inclusive_range f m start end_incl =
    try
      M.to_seq_from start !m
      |> Seq.iter (fun (k, v) ->
             if Ord.compare k end_incl <= 0 then f k v else raise Exit )
    with Exit -> ()

  let fold f m acc = M.fold f !m acc

  let exists f m = M.exists f !m

  let min_binding m = M.min_binding !m

  let max_binding m = M.max_binding !m

  let find_first_opt m k =
    M.find_first_opt (fun k' -> Ord.compare k k' <= 0) !m

  let find_last_opt m k = M.find_last_opt (fun k' -> Ord.compare k' k < 0) !m

  let find_first m k = M.find_first (fun k' -> Ord.compare k k' <= 0) !m

  let find_last m k = M.find_last (fun k' -> Ord.compare k' k < 0) !m

  let split_off_after m k =
    let m1, m2 = M.partition (fun k' _v -> Ord.compare k k' >= 0) !m in
    m := m1;
    ref m2

  let split_off_le m k =
    let m1, m2 = M.partition (fun k' _v -> Ord.compare k k' < 0) !m in
    m := m1;
    ref m2

  let carve_inclusive_range m start end_incl =
    let m1, m2 =
      M.partition
        (fun k _v -> Ord.compare start k > 0 || Ord.compare k end_incl > 0)
        !m
    in
    m := m1;
    ref m2

  let keys m = List.rev (fold (fun k _v acc -> k :: acc) m [])

  let swap m1 m2 =
    let m = !m1 in
    m1 := !m2;
    m2 := m

  let copy_in m1 m2 =
    let () = clear m2 in
    M.iter (add m2) !m1
end
