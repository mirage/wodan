module type LRUValue = sig
  type t

  val discardable : t -> bool
end

module Make (K : Hashtbl.HashedType) (V : LRUValue) = struct
  module Val = struct
    include V

    let weight _ = 1
  end

  module LRU = Lru.M.Make (K) (Val)

  type t = LRU.t

  type key = K.t

  type value = V.t

  exception Already_cached of key

  exception Too_small

  let get_opt t k = LRU.find ~promote:true k t

  let get t k =
    match get_opt t k with
    | None ->
        raise Not_found
    | Some x ->
        x

  let peek_opt t k = LRU.find ~promote:false k t

  let peek t k =
    match peek_opt t k with
    | None ->
        raise Not_found
    | Some x ->
        x

  let xadd t k v =
    if LRU.mem k t then raise @@ Already_cached k else LRU.add k v t

  let add t k v = LRU.add k v t

  let mem t k = LRU.mem k t

  let items = LRU.items

  let size = LRU.size

  let capacity = LRU.capacity

  let lru = LRU.lru

  let create = LRU.create ~random:false

  let safe_add t k v =
    if size t + Val.weight v > capacity t then
      match LRU.lru t with
      | Some (_, entry)
        when not @@ Val.discardable entry ->
          raise Too_small
      | _ ->
          add t k v

  let safe_xadd t k v =
    if size t + Val.weight v > capacity t then
      match LRU.lru t with
      | Some (_, entry)
        when not @@ Val.discardable entry ->
          raise Too_small
      | _ ->
          xadd t k v
end
