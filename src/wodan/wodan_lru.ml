module type Params = sig
  module Key : Hashtbl.HashedType

  module Value : sig
    type t

    val discardable : t -> bool

    val on_discard : t -> (Key.t -> t) -> unit
  end
end

module Make (P : Params) = struct
  module Val = struct
    include P.Value

    let weight _ = 1
  end

  module Key = P.Key
  module LRU = Lru.M.Make (Key) (Val)

  type t = LRU.t

  type key = Key.t

  type value = Val.t

  exception MissingLRUEntry of key

  exception Already_cached of key

  exception Too_small

  let get_opt t k = LRU.find ~promote:true k t

  let get t k =
    match get_opt t k with
    | None ->
        raise (MissingLRUEntry k)
    | Some x ->
        x

  let peek_opt t k = LRU.find ~promote:false k t

  let peek t k =
    match peek_opt t k with
    | None ->
        raise (MissingLRUEntry k)
    | Some x ->
        x

  let xadd t k v =
    if LRU.mem k t then raise (Already_cached k) else LRU.add k v t

  let add t k v = LRU.add k v t

  let mem t k = LRU.mem k t

  let items = LRU.items

  let size = LRU.size

  let capacity = LRU.capacity

  let lru = LRU.lru

  let create = LRU.create ~random:false

  let checks t v =
    if size t + Val.weight v > capacity t then
      match LRU.lru t with
      | Some (_, entry)
        when not (Val.discardable entry) ->
          raise Too_small
      | Some (_, entry) ->
          Val.on_discard entry (peek t)
      | _ ->
          ()

  let safe_add t k v =
    let () = checks t v in
    add t k v

  let safe_xadd t k v =
    let () = checks t v in
    xadd t k v
end
