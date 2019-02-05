module Log : Logs.LOG

val standard_mount_options : Wodan.mount_options

module Conf : sig
  val path : string Irmin.Private.Conf.key

  val create : bool Irmin.Private.Conf.key

  val cache_size : int Irmin.Private.Conf.key

  val fast_scan : bool Irmin.Private.Conf.key

  val list_key : string Irmin.Private.Conf.key

  val autoflush : bool Irmin.Private.Conf.key
end

val config :
  ?config:Irmin.config ->
  path:string ->
  create:bool ->
  ?cache_size:int ->
  ?fast_scan:bool ->
  ?list_key:string ->
  ?autoflush:bool ->
  unit ->
  Irmin.config

module type BLOCK_CON = sig
  include Wodan.EXTBLOCK

  val connect : string -> t io
end

module type DB = sig
  module Stor : Wodan.S

  type t

  val db_root : t -> Stor.root

  val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

  val v : Irmin.config -> t Lwt.t

  val flush : t -> int64 Lwt.t
end

module DB_BUILDER : functor (_ : BLOCK_CON) (_ : Wodan.SUPERBLOCK_PARAMS) -> DB

module RO_BUILDER (DB : DB) (K : Irmin.Hash.S) (V : Irmin.Type.S) : sig
  type t

  type key = K.t

  type value = V.t

  val mem : t -> key -> bool Lwt.t

  val find : t -> key -> value option Lwt.t

  module Stor : Wodan.S

  val db_root : t -> Stor.root

  val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

  val v : Irmin.config -> t Lwt.t

  val flush : t -> int64 Lwt.t
end

module AO_BUILDER : functor (_ : DB) -> Irmin.AO_MAKER

module LINK_BUILDER : functor (_ : DB) -> Irmin.LINK_MAKER

module RW_BUILDER : functor (_ : DB) (_ : Irmin.Hash.S) -> Irmin.RW_MAKER

module Make
    (DB : DB)
    (M : Irmin.Metadata.S)
    (C : Irmin.Contents.S)
    (P : Irmin.Path.S)
    (B : Irmin.Branch.S)
    (H : Irmin.Hash.S) : sig
  module DB : sig
    module Stor : Wodan.S

    type t = DB.t

    val db_root : t -> Stor.root

    val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

    val v : Irmin.config -> t Lwt.t

    val flush : t -> int64 Lwt.t
  end

  module AO (K : Irmin.Hash.S) (V : Irmin.Type.S) : sig
    type t = AO_BUILDER(DB)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val add : t -> value -> key Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  module RW (K : Irmin.Type.S) (V : Irmin.Type.S) : sig
    type t = RW_BUILDER(DB)(H)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val set : t -> key -> value -> unit Lwt.t

    val test_and_set :
      t -> key -> test:value option -> set:value option -> bool Lwt.t

    val remove : t -> key -> unit Lwt.t

    val list : t -> key list Lwt.t

    type watch = RW_BUILDER(DB)(H)(K)(V).watch

    val watch :
      t ->
      ?init:(key * value) list ->
      (key -> value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_key :
      t ->
      key ->
      ?init:value ->
      (value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val unwatch : t -> watch -> unit Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  type repo = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).repo

  type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).t

  type step = P.step

  type key = P.t

  type metadata = M.t

  type contents = C.t

  type node = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).node

  type tree =
    [ `Contents of contents * metadata
    | `Node of node ]

  type commit = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).commit

  type branch = B.t

  type slice = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).slice

  type lca_error =
    [ `Max_depth_reached
    | `Too_many_lcas ]

  type ff_error =
    [ `Max_depth_reached
    | `No_change
    | `Rejected
    | `Too_many_lcas ]

  module Repo : sig
    type t = repo

    val v : Irmin.config -> t Lwt.t

    val heads : t -> commit list Lwt.t

    val branches : t -> branch list Lwt.t

    val export :
      ?full:bool ->
      ?depth:int ->
      ?min:commit list ->
      ?max:commit list ->
      t ->
      slice Lwt.t

    val import : t -> slice -> (unit, [`Msg of string]) result Lwt.t
  end

  val empty : repo -> t Lwt.t

  val master : repo -> t Lwt.t

  val of_branch : repo -> branch -> t Lwt.t

  val of_commit : commit -> t Lwt.t

  val repo : t -> repo

  val tree : t -> tree Lwt.t

  module Status : sig
    type t =
      [ `Branch of branch
      | `Commit of commit
      | `Empty ]

    val t : repo -> t Irmin.Type.ty

    val pp : t Fmt.t
  end

  val status : t -> Status.t

  module Head : sig
    val list : repo -> commit list Lwt.t

    val find : t -> commit option Lwt.t

    val get : t -> commit Lwt.t

    val set : t -> commit -> unit Lwt.t

    val fast_forward :
      t ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      ( unit,
        [`Max_depth_reached | `No_change | `Rejected | `Too_many_lcas] )
      result
      Lwt.t

    val test_and_set :
      t -> test:commit option -> set:commit option -> bool Lwt.t

    val merge :
      into:t ->
      info:Irmin.Info.f ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      (unit, Irmin.Merge.conflict) result Lwt.t
  end

  module Commit : sig
    type t = commit

    val t : repo -> t Irmin.Type.ty

    val pp_hash : t Fmt.t

    val v : repo -> info:Irmin.Info.t -> parents:t list -> tree -> t Lwt.t

    val tree : t -> tree Lwt.t

    val parents : t -> t list Lwt.t

    val info : t -> Irmin.Info.t

    module Hash : sig
      type t = H.t

      val digest : string -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : t -> hash

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Contents : sig
    type t = contents

    val t : t Irmin.Type.ty

    val merge : t option Irmin.Merge.t

    module Hash : sig
      type t = Commit.hash

      val digest : string -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : repo -> t -> hash Lwt.t

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Tree : sig
    val empty : tree

    val of_contents : ?metadata:metadata -> contents -> tree

    val of_node : node -> tree

    val kind : tree -> key -> [`Contents | `Node] option Lwt.t

    val list : tree -> key -> (step * [`Contents | `Node]) list Lwt.t

    val diff :
      tree -> tree -> (key * (contents * metadata) Irmin.diff) list Lwt.t

    val mem : tree -> key -> bool Lwt.t

    val find_all : tree -> key -> (contents * metadata) option Lwt.t

    val find : tree -> key -> contents option Lwt.t

    val get_all : tree -> key -> (contents * metadata) Lwt.t

    val get : tree -> key -> contents Lwt.t

    val add : tree -> key -> ?metadata:metadata -> contents -> tree Lwt.t

    val remove : tree -> key -> tree Lwt.t

    val mem_tree : tree -> key -> bool Lwt.t

    val find_tree : tree -> key -> tree option Lwt.t

    val get_tree : tree -> key -> tree Lwt.t

    val add_tree : tree -> key -> tree -> tree Lwt.t

    val merge : tree Irmin.Merge.t

    val clear_caches : tree -> unit

    type marks = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Tree.marks

    val empty_marks : unit -> marks

    type 'a force =
      [ `False of key -> 'a -> 'a Lwt.t
      | `True ]

    type uniq =
      [ `False
      | `Marks of marks
      | `True ]

    type 'a node_fn = key -> step list -> 'a -> 'a Lwt.t

    val fold :
      ?force:'a force ->
      ?uniq:uniq ->
      ?pre:'a node_fn ->
      ?post:'a node_fn ->
      (key -> contents -> 'a -> 'a Lwt.t) ->
      tree ->
      'a ->
      'a Lwt.t

    type stats = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Tree.stats = {
      nodes : int;
      leafs : int;
      skips : int;
      depth : int;
      width : int
    }

    val pp_stats : stats Fmt.t

    val stats : ?force:bool -> tree -> stats Lwt.t

    type concrete =
      [ `Contents of contents * metadata
      | `Tree of (step * concrete) list ]

    val of_concrete : concrete -> tree

    val to_concrete : tree -> concrete Lwt.t

    module Hash : sig
      type t = Contents.hash

      val digest : string -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash =
      [ `Contents of Hash.t * metadata
      | `Node of Hash.t ]

    val hash_t : hash Irmin.Type.ty

    val hash : repo -> tree -> hash Lwt.t

    val of_hash : repo -> hash -> tree option Lwt.t
  end

  val kind : t -> key -> [`Contents | `Node] option Lwt.t

  val list : t -> key -> (step * [`Contents | `Node]) list Lwt.t

  val mem : t -> key -> bool Lwt.t

  val mem_tree : t -> key -> bool Lwt.t

  val find_all : t -> key -> (contents * metadata) option Lwt.t

  val find : t -> key -> contents option Lwt.t

  val get_all : t -> key -> (contents * metadata) Lwt.t

  val get : t -> key -> contents Lwt.t

  val find_tree : t -> key -> tree option Lwt.t

  val get_tree : t -> key -> tree Lwt.t

  type 'a transaction =
    ?retries:int ->
    ?allow_empty:bool ->
    ?strategy:[`Merge_with_parent of commit | `Set | `Test_and_set] ->
    info:Irmin.Info.f ->
    'a ->
    unit Lwt.t

  val with_tree : t -> key -> (tree option -> tree option Lwt.t) transaction

  val set : t -> key -> ?metadata:metadata -> contents transaction

  val set_tree : t -> key -> tree transaction

  val remove : t -> key transaction

  val clone : src:t -> dst:branch -> t Lwt.t

  type watch = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).watch

  val watch :
    t -> ?init:commit -> (commit Irmin.diff -> unit Lwt.t) -> watch Lwt.t

  val watch_key :
    t ->
    key ->
    ?init:commit ->
    ((commit * tree) Irmin.diff -> unit Lwt.t) ->
    watch Lwt.t

  val unwatch : watch -> unit Lwt.t

  type 'a merge =
    info:Irmin.Info.f ->
    ?max_depth:int ->
    ?n:int ->
    'a ->
    (unit, Irmin.Merge.conflict) result Lwt.t

  val merge : into:t -> t merge

  val merge_with_branch : t -> branch merge

  val merge_with_commit : t -> commit merge

  val lcas :
    ?max_depth:int ->
    ?n:int ->
    t ->
    t ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_branch :
    t ->
    ?max_depth:int ->
    ?n:int ->
    branch ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_commit :
    t ->
    ?max_depth:int ->
    ?n:int ->
    commit ->
    (commit list, lca_error) result Lwt.t

  module History : sig
    type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.t

    module V : sig
      type t = commit

      val compare : t -> t -> int

      val hash : t -> int

      val equal : t -> t -> bool

      type label = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.V.label

      val create : label -> t

      val label : t -> label
    end

    type vertex = commit

    module E : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.E.t

      val compare : t -> t -> int

      type vertex = commit

      val src : t -> vertex

      val dst : t -> vertex

      type label = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.E.label

      val create : vertex -> label -> vertex -> t

      val label : t -> label
    end

    type edge = E.t

    val is_directed : bool

    val is_empty : t -> bool

    val nb_vertex : t -> int

    val nb_edges : t -> int

    val out_degree : t -> vertex -> int

    val in_degree : t -> vertex -> int

    val mem_vertex : t -> vertex -> bool

    val mem_edge : t -> vertex -> vertex -> bool

    val mem_edge_e : t -> edge -> bool

    val find_edge : t -> vertex -> vertex -> edge

    val find_all_edges : t -> vertex -> vertex -> edge list

    val succ : t -> vertex -> vertex list

    val pred : t -> vertex -> vertex list

    val succ_e : t -> vertex -> edge list

    val pred_e : t -> vertex -> edge list

    val iter_vertex : (vertex -> unit) -> t -> unit

    val fold_vertex : (vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges : (vertex -> vertex -> unit) -> t -> unit

    val fold_edges : (vertex -> vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges_e : (edge -> unit) -> t -> unit

    val fold_edges_e : (edge -> 'a -> 'a) -> t -> 'a -> 'a

    val map_vertex : (vertex -> vertex) -> t -> t

    val iter_succ : (vertex -> unit) -> t -> vertex -> unit

    val iter_pred : (vertex -> unit) -> t -> vertex -> unit

    val fold_succ : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val fold_pred : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_succ_e : (edge -> unit) -> t -> vertex -> unit

    val fold_succ_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_pred_e : (edge -> unit) -> t -> vertex -> unit

    val fold_pred_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val empty : t

    val add_vertex : t -> vertex -> t

    val remove_vertex : t -> vertex -> t

    val add_edge : t -> vertex -> vertex -> t

    val add_edge_e : t -> edge -> t

    val remove_edge : t -> vertex -> vertex -> t

    val remove_edge_e : t -> edge -> t
  end

  val history :
    ?depth:int -> ?min:commit list -> ?max:commit list -> t -> History.t Lwt.t

  module Branch : sig
    val mem : repo -> branch -> bool Lwt.t

    val find : repo -> branch -> commit option Lwt.t

    val get : repo -> branch -> commit Lwt.t

    val set : repo -> branch -> commit -> unit Lwt.t

    val remove : repo -> branch -> unit Lwt.t

    val list : repo -> branch list Lwt.t

    val watch :
      repo ->
      branch ->
      ?init:commit ->
      (commit Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_all :
      repo ->
      ?init:(branch * commit) list ->
      (branch -> commit Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    type t = branch

    val t : t Irmin.Type.ty

    val master : t

    val is_valid : t -> bool
  end

  module Key : sig
    type t = key

    type step = P.step

    val empty : t

    val v : step list -> t

    val is_empty : t -> bool

    val cons : step -> t -> t

    val rcons : t -> step -> t

    val decons : t -> (step * t) option

    val rdecons : t -> (t * step) option

    val map : t -> (step -> 'a) -> 'a list

    val t : t Irmin.Type.ty

    val step_t : step Irmin.Type.ty
  end

  module Metadata : sig
    type t = metadata

    val t : t Irmin.Type.ty

    val merge : t Irmin.Merge.t

    val default : t
  end

  val step_t : step Irmin.Type.ty

  val key_t : key Irmin.Type.ty

  val metadata_t : metadata Irmin.Type.ty

  val contents_t : contents Irmin.Type.ty

  val node_t : node Irmin.Type.ty

  val tree_t : tree Irmin.Type.ty

  val commit_t : repo -> commit Irmin.Type.ty

  val branch_t : branch Irmin.Type.ty

  val slice_t : slice Irmin.Type.ty

  val kind_t : [`Contents | `Node] Irmin.Type.ty

  val lca_error_t : lca_error Irmin.Type.ty

  val ff_error_t : ff_error Irmin.Type.ty

  module Private : sig
    module Contents : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Contents.t

      type key = Contents.hash

      type value = contents

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        val t : t Irmin.Type.ty

        val merge : t option Irmin.Merge.t
      end
    end

    module Node : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.t

      type key = Contents.key

      type value = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      module Path : sig
        type t = Key.t

        type step = Key.step

        val empty : t

        val v : step list -> t

        val is_empty : t -> bool

        val cons : step -> t -> t

        val rcons : t -> step -> t

        val decons : t -> (step * t) option

        val rdecons : t -> (t * step) option

        val map : t -> (step -> 'a) -> 'a list

        val t : t Irmin.Type.ty

        val step_t : step Irmin.Type.ty
      end

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Metadata : sig
        type t = metadata

        val t : t Irmin.Type.ty

        val merge : t Irmin.Merge.t

        val default : t
      end

      module Val : sig
        type t = value

        type metadata = Metadata.t

        type contents = key

        type node = contents

        type step = Path.step

        type value =
          [ `Contents of node * metadata
          | `Node of node ]

        val v : (step * value) list -> t

        val list : t -> (step * value) list

        val empty : t

        val is_empty : t -> bool

        val find : t -> step -> value option

        val update : t -> step -> value -> t

        val remove : t -> step -> t

        val t : t Irmin.Type.ty

        val metadata_t : metadata Irmin.Type.ty

        val contents_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty

        val step_t : step Irmin.Type.ty

        val value_t : value Irmin.Type.ty
      end

      module Contents : sig
        type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.Contents.t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.Contents.value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : string -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Val : sig
          type t = value

          val t : t Irmin.Type.ty

          val merge : t option Irmin.Merge.t
        end
      end
    end

    module Commit : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.t

      type key = Node.key

      type value = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> info:Irmin.Info.f -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        type commit = key

        type node = commit

        val v : info:Irmin.Info.t -> node:node -> parents:node list -> t

        val node : t -> node

        val parents : t -> node list

        val info : t -> Irmin.Info.t

        val t : t Irmin.Type.ty

        val commit_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty
      end

      module Node : sig
        type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        module Path : sig
          type t =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Path.t

          type step =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Path.step

          val empty : t

          val v : step list -> t

          val is_empty : t -> bool

          val cons : step -> t -> t

          val rcons : t -> step -> t

          val decons : t -> (step * t) option

          val rdecons : t -> (t * step) option

          val map : t -> (step -> 'a) -> 'a list

          val t : t Irmin.Type.ty

          val step_t : step Irmin.Type.ty
        end

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : string -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Metadata : sig
          type t =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Metadata.t

          val t : t Irmin.Type.ty

          val merge : t Irmin.Merge.t

          val default : t
        end

        module Val : sig
          type t = value

          type metadata = Metadata.t

          type contents =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Val.contents

          type node = key

          type step = Path.step

          type value =
            [ `Contents of contents * metadata
            | `Node of node ]

          val v : (step * value) list -> t

          val list : t -> (step * value) list

          val empty : t

          val is_empty : t -> bool

          val find : t -> step -> value option

          val update : t -> step -> value -> t

          val remove : t -> step -> t

          val t : t Irmin.Type.ty

          val metadata_t : metadata Irmin.Type.ty

          val contents_t : contents Irmin.Type.ty

          val node_t : node Irmin.Type.ty

          val step_t : step Irmin.Type.ty

          val value_t : value Irmin.Type.ty
        end

        module Contents : sig
          type t =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Contents.t

          type key = Val.contents

          type value =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Contents
            .value

          val mem : t -> key -> bool Lwt.t

          val find : t -> key -> value option Lwt.t

          val add : t -> value -> key Lwt.t

          val merge : t -> key option Irmin.Merge.t

          module Key : sig
            type t = key

            val digest : string -> t

            val hash : t -> int

            val digest_size : int

            val t : t Irmin.Type.ty
          end

          module Val : sig
            type t = value

            val t : t Irmin.Type.ty

            val merge : t option Irmin.Merge.t
          end
        end
      end
    end

    module Branch : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Branch.t

      type key = branch

      type value = Commit.key

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val set : t -> key -> value -> unit Lwt.t

      val test_and_set :
        t -> key -> test:value option -> set:value option -> bool Lwt.t

      val remove : t -> key -> unit Lwt.t

      type watch = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Branch.watch

      val watch :
        t ->
        ?init:(key * value) list ->
        (key -> value Irmin.diff -> unit Lwt.t) ->
        watch Lwt.t

      val watch_key :
        t ->
        key ->
        ?init:value ->
        (value Irmin.diff -> unit Lwt.t) ->
        watch Lwt.t

      val unwatch : t -> watch -> unit Lwt.t

      val list : t -> key list Lwt.t

      module Key : sig
        type t = key

        val t : t Irmin.Type.ty

        val master : t

        val is_valid : t -> bool
      end

      module Val : sig
        type t = value

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end
    end

    module Slice : sig
      type t = slice

      type contents = Branch.value * Contents.value

      type node = Branch.value * Node.value

      type commit = Branch.value * Commit.value

      type value =
        [ `Commit of commit
        | `Contents of contents
        | `Node of node ]

      val empty : unit -> t Lwt.t

      val add : t -> value -> unit Lwt.t

      val iter : t -> (value -> unit Lwt.t) -> unit Lwt.t

      val t : t Irmin.Type.ty

      val contents_t : contents Irmin.Type.ty

      val node_t : node Irmin.Type.ty

      val commit_t : commit Irmin.Type.ty

      val value_t : value Irmin.Type.ty
    end

    module Repo : sig
      type t = repo

      val v : Irmin.config -> t Lwt.t

      val contents_t : t -> Contents.t

      val node_t : t -> Node.t

      val commit_t : t -> Commit.t

      val branch_t : t -> Branch.t
    end

    module Sync : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Sync.t

      type commit = Branch.value

      type branch = Branch.key

      type endpoint = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Sync.endpoint

      val fetch :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        (commit, [`Msg of string | `No_head | `Not_available]) result Lwt.t

      val push :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        ( unit,
          [`Detached_head | `Msg of string | `No_head | `Not_available] )
        result
        Lwt.t

      val v : repo -> t Lwt.t
    end
  end

  type Irmin.remote += E of Private.Sync.endpoint

  val flush : DB.t -> int64 Lwt.t
end

module Make_chunked
    (DB : DB)
    (M : Irmin.Metadata.S)
    (C : Irmin.Contents.S)
    (P : Irmin.Path.S)
    (B : Irmin.Branch.S)
    (H : Irmin.Hash.S) : sig
  module AO (K : Irmin.Hash.S) (V : Irmin.Type.S) : sig
    type t = Irmin_chunk.AO(AO_BUILDER(DB))(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val add : t -> value -> key Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  module DB : sig
    module Stor : Wodan.S

    type t = DB.t

    val db_root : t -> Stor.root

    val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

    val v : Irmin.config -> t Lwt.t

    val flush : t -> int64 Lwt.t
  end

  module RW (K : Irmin.Type.S) (V : Irmin.Type.S) : sig
    type t = RW_BUILDER(DB)(H)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val set : t -> key -> value -> unit Lwt.t

    val test_and_set :
      t -> key -> test:value option -> set:value option -> bool Lwt.t

    val remove : t -> key -> unit Lwt.t

    val list : t -> key list Lwt.t

    type watch = RW_BUILDER(DB)(H)(K)(V).watch

    val watch :
      t ->
      ?init:(key * value) list ->
      (key -> value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_key :
      t ->
      key ->
      ?init:value ->
      (value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val unwatch : t -> watch -> unit Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  type repo = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).repo

  type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).t

  type step = P.step

  type key = P.t

  type metadata = M.t

  type contents = C.t

  type node = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).node

  type tree =
    [ `Contents of contents * metadata
    | `Node of node ]

  type commit = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).commit

  type branch = B.t

  type slice = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).slice

  type lca_error =
    [ `Max_depth_reached
    | `Too_many_lcas ]

  type ff_error =
    [ `Max_depth_reached
    | `No_change
    | `Rejected
    | `Too_many_lcas ]

  module Repo : sig
    type t = repo

    val v : Irmin.config -> t Lwt.t

    val heads : t -> commit list Lwt.t

    val branches : t -> branch list Lwt.t

    val export :
      ?full:bool ->
      ?depth:int ->
      ?min:commit list ->
      ?max:commit list ->
      t ->
      slice Lwt.t

    val import : t -> slice -> (unit, [`Msg of string]) result Lwt.t
  end

  val empty : repo -> t Lwt.t

  val master : repo -> t Lwt.t

  val of_branch : repo -> branch -> t Lwt.t

  val of_commit : commit -> t Lwt.t

  val repo : t -> repo

  val tree : t -> tree Lwt.t

  module Status : sig
    type t =
      [ `Branch of branch
      | `Commit of commit
      | `Empty ]

    val t : repo -> t Irmin.Type.ty

    val pp : t Fmt.t
  end

  val status : t -> Status.t

  module Head : sig
    val list : repo -> commit list Lwt.t

    val find : t -> commit option Lwt.t

    val get : t -> commit Lwt.t

    val set : t -> commit -> unit Lwt.t

    val fast_forward :
      t ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      ( unit,
        [`Max_depth_reached | `No_change | `Rejected | `Too_many_lcas] )
      result
      Lwt.t

    val test_and_set :
      t -> test:commit option -> set:commit option -> bool Lwt.t

    val merge :
      into:t ->
      info:Irmin.Info.f ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      (unit, Irmin.Merge.conflict) result Lwt.t
  end

  module Commit : sig
    type t = commit

    val t : repo -> t Irmin.Type.ty

    val pp_hash : t Fmt.t

    val v : repo -> info:Irmin.Info.t -> parents:t list -> tree -> t Lwt.t

    val tree : t -> tree Lwt.t

    val parents : t -> t list Lwt.t

    val info : t -> Irmin.Info.t

    module Hash : sig
      type t = H.t

      val digest : string -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : t -> hash

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Contents : sig
    type t = contents

    val t : t Irmin.Type.ty

    val merge : t option Irmin.Merge.t

    module Hash : sig
      type t = Commit.hash

      val digest : string -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : repo -> t -> hash Lwt.t

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Tree : sig
    val empty : tree

    val of_contents : ?metadata:metadata -> contents -> tree

    val of_node : node -> tree

    val kind : tree -> key -> [`Contents | `Node] option Lwt.t

    val list : tree -> key -> (step * [`Contents | `Node]) list Lwt.t

    val diff :
      tree -> tree -> (key * (contents * metadata) Irmin.diff) list Lwt.t

    val mem : tree -> key -> bool Lwt.t

    val find_all : tree -> key -> (contents * metadata) option Lwt.t

    val find : tree -> key -> contents option Lwt.t

    val get_all : tree -> key -> (contents * metadata) Lwt.t

    val get : tree -> key -> contents Lwt.t

    val add : tree -> key -> ?metadata:metadata -> contents -> tree Lwt.t

    val remove : tree -> key -> tree Lwt.t

    val mem_tree : tree -> key -> bool Lwt.t

    val find_tree : tree -> key -> tree option Lwt.t

    val get_tree : tree -> key -> tree Lwt.t

    val add_tree : tree -> key -> tree -> tree Lwt.t

    val merge : tree Irmin.Merge.t

    val clear_caches : tree -> unit

    type marks = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Tree.marks

    val empty_marks : unit -> marks

    type 'a force =
      [ `False of key -> 'a -> 'a Lwt.t
      | `True ]

    type uniq =
      [ `False
      | `Marks of marks
      | `True ]

    type 'a node_fn = key -> step list -> 'a -> 'a Lwt.t

    val fold :
      ?force:'a force ->
      ?uniq:uniq ->
      ?pre:'a node_fn ->
      ?post:'a node_fn ->
      (key -> contents -> 'a -> 'a Lwt.t) ->
      tree ->
      'a ->
      'a Lwt.t

    type stats = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Tree.stats = {
      nodes : int;
      leafs : int;
      skips : int;
      depth : int;
      width : int
    }

    val pp_stats : stats Fmt.t

    val stats : ?force:bool -> tree -> stats Lwt.t

    type concrete =
      [ `Contents of contents * metadata
      | `Tree of (step * concrete) list ]

    val of_concrete : concrete -> tree

    val to_concrete : tree -> concrete Lwt.t

    module Hash : sig
      type t = Contents.hash

      val digest : string -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash =
      [ `Contents of Hash.t * metadata
      | `Node of Hash.t ]

    val hash_t : hash Irmin.Type.ty

    val hash : repo -> tree -> hash Lwt.t

    val of_hash : repo -> hash -> tree option Lwt.t
  end

  val kind : t -> key -> [`Contents | `Node] option Lwt.t

  val list : t -> key -> (step * [`Contents | `Node]) list Lwt.t

  val mem : t -> key -> bool Lwt.t

  val mem_tree : t -> key -> bool Lwt.t

  val find_all : t -> key -> (contents * metadata) option Lwt.t

  val find : t -> key -> contents option Lwt.t

  val get_all : t -> key -> (contents * metadata) Lwt.t

  val get : t -> key -> contents Lwt.t

  val find_tree : t -> key -> tree option Lwt.t

  val get_tree : t -> key -> tree Lwt.t

  type 'a transaction =
    ?retries:int ->
    ?allow_empty:bool ->
    ?strategy:[`Merge_with_parent of commit | `Set | `Test_and_set] ->
    info:Irmin.Info.f ->
    'a ->
    unit Lwt.t

  val with_tree : t -> key -> (tree option -> tree option Lwt.t) transaction

  val set : t -> key -> ?metadata:metadata -> contents transaction

  val set_tree : t -> key -> tree transaction

  val remove : t -> key transaction

  val clone : src:t -> dst:branch -> t Lwt.t

  type watch = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).watch

  val watch :
    t -> ?init:commit -> (commit Irmin.diff -> unit Lwt.t) -> watch Lwt.t

  val watch_key :
    t ->
    key ->
    ?init:commit ->
    ((commit * tree) Irmin.diff -> unit Lwt.t) ->
    watch Lwt.t

  val unwatch : watch -> unit Lwt.t

  type 'a merge =
    info:Irmin.Info.f ->
    ?max_depth:int ->
    ?n:int ->
    'a ->
    (unit, Irmin.Merge.conflict) result Lwt.t

  val merge : into:t -> t merge

  val merge_with_branch : t -> branch merge

  val merge_with_commit : t -> commit merge

  val lcas :
    ?max_depth:int ->
    ?n:int ->
    t ->
    t ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_branch :
    t ->
    ?max_depth:int ->
    ?n:int ->
    branch ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_commit :
    t ->
    ?max_depth:int ->
    ?n:int ->
    commit ->
    (commit list, lca_error) result Lwt.t

  module History : sig
    type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.t

    module V : sig
      type t = commit

      val compare : t -> t -> int

      val hash : t -> int

      val equal : t -> t -> bool

      type label = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.V.label

      val create : label -> t

      val label : t -> label
    end

    type vertex = commit

    module E : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.E.t

      val compare : t -> t -> int

      type vertex = commit

      val src : t -> vertex

      val dst : t -> vertex

      type label = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).History.E.label

      val create : vertex -> label -> vertex -> t

      val label : t -> label
    end

    type edge = E.t

    val is_directed : bool

    val is_empty : t -> bool

    val nb_vertex : t -> int

    val nb_edges : t -> int

    val out_degree : t -> vertex -> int

    val in_degree : t -> vertex -> int

    val mem_vertex : t -> vertex -> bool

    val mem_edge : t -> vertex -> vertex -> bool

    val mem_edge_e : t -> edge -> bool

    val find_edge : t -> vertex -> vertex -> edge

    val find_all_edges : t -> vertex -> vertex -> edge list

    val succ : t -> vertex -> vertex list

    val pred : t -> vertex -> vertex list

    val succ_e : t -> vertex -> edge list

    val pred_e : t -> vertex -> edge list

    val iter_vertex : (vertex -> unit) -> t -> unit

    val fold_vertex : (vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges : (vertex -> vertex -> unit) -> t -> unit

    val fold_edges : (vertex -> vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges_e : (edge -> unit) -> t -> unit

    val fold_edges_e : (edge -> 'a -> 'a) -> t -> 'a -> 'a

    val map_vertex : (vertex -> vertex) -> t -> t

    val iter_succ : (vertex -> unit) -> t -> vertex -> unit

    val iter_pred : (vertex -> unit) -> t -> vertex -> unit

    val fold_succ : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val fold_pred : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_succ_e : (edge -> unit) -> t -> vertex -> unit

    val fold_succ_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_pred_e : (edge -> unit) -> t -> vertex -> unit

    val fold_pred_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val empty : t

    val add_vertex : t -> vertex -> t

    val remove_vertex : t -> vertex -> t

    val add_edge : t -> vertex -> vertex -> t

    val add_edge_e : t -> edge -> t

    val remove_edge : t -> vertex -> vertex -> t

    val remove_edge_e : t -> edge -> t
  end

  val history :
    ?depth:int -> ?min:commit list -> ?max:commit list -> t -> History.t Lwt.t

  module Branch : sig
    val mem : repo -> branch -> bool Lwt.t

    val find : repo -> branch -> commit option Lwt.t

    val get : repo -> branch -> commit Lwt.t

    val set : repo -> branch -> commit -> unit Lwt.t

    val remove : repo -> branch -> unit Lwt.t

    val list : repo -> branch list Lwt.t

    val watch :
      repo ->
      branch ->
      ?init:commit ->
      (commit Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_all :
      repo ->
      ?init:(branch * commit) list ->
      (branch -> commit Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    type t = branch

    val t : t Irmin.Type.ty

    val master : t

    val is_valid : t -> bool
  end

  module Key : sig
    type t = key

    type step = P.step

    val empty : t

    val v : step list -> t

    val is_empty : t -> bool

    val cons : step -> t -> t

    val rcons : t -> step -> t

    val decons : t -> (step * t) option

    val rdecons : t -> (t * step) option

    val map : t -> (step -> 'a) -> 'a list

    val t : t Irmin.Type.ty

    val step_t : step Irmin.Type.ty
  end

  module Metadata : sig
    type t = metadata

    val t : t Irmin.Type.ty

    val merge : t Irmin.Merge.t

    val default : t
  end

  val step_t : step Irmin.Type.ty

  val key_t : key Irmin.Type.ty

  val metadata_t : metadata Irmin.Type.ty

  val contents_t : contents Irmin.Type.ty

  val node_t : node Irmin.Type.ty

  val tree_t : tree Irmin.Type.ty

  val commit_t : repo -> commit Irmin.Type.ty

  val branch_t : branch Irmin.Type.ty

  val slice_t : slice Irmin.Type.ty

  val kind_t : [`Contents | `Node] Irmin.Type.ty

  val lca_error_t : lca_error Irmin.Type.ty

  val ff_error_t : ff_error Irmin.Type.ty

  module Private : sig
    module Contents : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Contents.t

      type key = Contents.hash

      type value = contents

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        val t : t Irmin.Type.ty

        val merge : t option Irmin.Merge.t
      end
    end

    module Node : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.t

      type key = Contents.key

      type value = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      module Path : sig
        type t = Key.t

        type step = Key.step

        val empty : t

        val v : step list -> t

        val is_empty : t -> bool

        val cons : step -> t -> t

        val rcons : t -> step -> t

        val decons : t -> (step * t) option

        val rdecons : t -> (t * step) option

        val map : t -> (step -> 'a) -> 'a list

        val t : t Irmin.Type.ty

        val step_t : step Irmin.Type.ty
      end

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Metadata : sig
        type t = metadata

        val t : t Irmin.Type.ty

        val merge : t Irmin.Merge.t

        val default : t
      end

      module Val : sig
        type t = value

        type metadata = Metadata.t

        type contents = key

        type node = contents

        type step = Path.step

        type value =
          [ `Contents of node * metadata
          | `Node of node ]

        val v : (step * value) list -> t

        val list : t -> (step * value) list

        val empty : t

        val is_empty : t -> bool

        val find : t -> step -> value option

        val update : t -> step -> value -> t

        val remove : t -> step -> t

        val t : t Irmin.Type.ty

        val metadata_t : metadata Irmin.Type.ty

        val contents_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty

        val step_t : step Irmin.Type.ty

        val value_t : value Irmin.Type.ty
      end

      module Contents : sig
        type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.Contents.t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Node.Contents.value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : string -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Val : sig
          type t = value

          val t : t Irmin.Type.ty

          val merge : t option Irmin.Merge.t
        end
      end
    end

    module Commit : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.t

      type key = Node.key

      type value = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> info:Irmin.Info.f -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        type commit = key

        type node = commit

        val v : info:Irmin.Info.t -> node:node -> parents:node list -> t

        val node : t -> node

        val parents : t -> node list

        val info : t -> Irmin.Info.t

        val t : t Irmin.Type.ty

        val commit_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty
      end

      module Node : sig
        type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        module Path : sig
          type t =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Path.t

          type step =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Path.step

          val empty : t

          val v : step list -> t

          val is_empty : t -> bool

          val cons : step -> t -> t

          val rcons : t -> step -> t

          val decons : t -> (step * t) option

          val rdecons : t -> (t * step) option

          val map : t -> (step -> 'a) -> 'a list

          val t : t Irmin.Type.ty

          val step_t : step Irmin.Type.ty
        end

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : string -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Metadata : sig
          type t =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Metadata.t

          val t : t Irmin.Type.ty

          val merge : t Irmin.Merge.t

          val default : t
        end

        module Val : sig
          type t = value

          type metadata = Metadata.t

          type contents =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Val.contents

          type node = key

          type step = Path.step

          type value =
            [ `Contents of contents * metadata
            | `Node of node ]

          val v : (step * value) list -> t

          val list : t -> (step * value) list

          val empty : t

          val is_empty : t -> bool

          val find : t -> step -> value option

          val update : t -> step -> value -> t

          val remove : t -> step -> t

          val t : t Irmin.Type.ty

          val metadata_t : metadata Irmin.Type.ty

          val contents_t : contents Irmin.Type.ty

          val node_t : node Irmin.Type.ty

          val step_t : step Irmin.Type.ty

          val value_t : value Irmin.Type.ty
        end

        module Contents : sig
          type t =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Contents.t

          type key = Val.contents

          type value =
            Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Commit.Node.Contents
            .value

          val mem : t -> key -> bool Lwt.t

          val find : t -> key -> value option Lwt.t

          val add : t -> value -> key Lwt.t

          val merge : t -> key option Irmin.Merge.t

          module Key : sig
            type t = key

            val digest : string -> t

            val hash : t -> int

            val digest_size : int

            val t : t Irmin.Type.ty
          end

          module Val : sig
            type t = value

            val t : t Irmin.Type.ty

            val merge : t option Irmin.Merge.t
          end
        end
      end
    end

    module Branch : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Branch.t

      type key = branch

      type value = Commit.key

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val set : t -> key -> value -> unit Lwt.t

      val test_and_set :
        t -> key -> test:value option -> set:value option -> bool Lwt.t

      val remove : t -> key -> unit Lwt.t

      type watch = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Branch.watch

      val watch :
        t ->
        ?init:(key * value) list ->
        (key -> value Irmin.diff -> unit Lwt.t) ->
        watch Lwt.t

      val watch_key :
        t ->
        key ->
        ?init:value ->
        (value Irmin.diff -> unit Lwt.t) ->
        watch Lwt.t

      val unwatch : t -> watch -> unit Lwt.t

      val list : t -> key list Lwt.t

      module Key : sig
        type t = key

        val t : t Irmin.Type.ty

        val master : t

        val is_valid : t -> bool
      end

      module Val : sig
        type t = value

        val digest : string -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end
    end

    module Slice : sig
      type t = slice

      type contents = Branch.value * Contents.value

      type node = Branch.value * Node.value

      type commit = Branch.value * Commit.value

      type value =
        [ `Commit of commit
        | `Contents of contents
        | `Node of node ]

      val empty : unit -> t Lwt.t

      val add : t -> value -> unit Lwt.t

      val iter : t -> (value -> unit Lwt.t) -> unit Lwt.t

      val t : t Irmin.Type.ty

      val contents_t : contents Irmin.Type.ty

      val node_t : node Irmin.Type.ty

      val commit_t : commit Irmin.Type.ty

      val value_t : value Irmin.Type.ty
    end

    module Repo : sig
      type t = repo

      val v : Irmin.config -> t Lwt.t

      val contents_t : t -> Contents.t

      val node_t : t -> Node.t

      val commit_t : t -> Commit.t

      val branch_t : t -> Branch.t
    end

    module Sync : sig
      type t = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Sync.t

      type commit = Branch.value

      type branch = Branch.key

      type endpoint = Irmin.Make(AO)(RW)(M)(C)(P)(B)(H).Private.Sync.endpoint

      val fetch :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        (commit, [`Msg of string | `No_head | `Not_available]) result Lwt.t

      val push :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        ( unit,
          [`Detached_head | `Msg of string | `No_head | `Not_available] )
        result
        Lwt.t

      val v : repo -> t Lwt.t
    end
  end

  type Irmin.remote += E of Private.Sync.endpoint

  val flush : DB.t -> int64 Lwt.t
end

module KV (DB : DB) (C : Irmin.Contents.S) : sig
  module DB : sig
    module Stor : Wodan.S

    type t = DB.t

    val db_root : t -> Stor.root

    val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

    val v : Irmin.config -> t Lwt.t

    val flush : t -> int64 Lwt.t
  end

  module AO (K : Irmin.Hash.S) (V : Irmin.Type.S) : sig
    type t = AO_BUILDER(DB)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val add : t -> value -> key Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  module RW (K : Irmin.Type.S) (V : Irmin.Type.S) : sig
    type t = RW_BUILDER(DB)(Irmin.Hash.SHA1)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val set : t -> key -> value -> unit Lwt.t

    val test_and_set :
      t -> key -> test:value option -> set:value option -> bool Lwt.t

    val remove : t -> key -> unit Lwt.t

    val list : t -> key list Lwt.t

    type watch = RW_BUILDER(DB)(Irmin.Hash.SHA1)(K)(V).watch

    val watch :
      t ->
      ?init:(key * value) list ->
      (key -> value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_key :
      t ->
      key ->
      ?init:value ->
      (value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val unwatch : t -> watch -> unit Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  type repo =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .repo

  type t =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .t

  type step = string

  type key = Irmin.Path.String_list.t

  type metadata = unit

  type contents = C.t

  type node =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .node

  type tree =
    [ `Contents of contents * metadata
    | `Node of node ]

  type commit =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .commit

  type branch = step

  type slice =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .slice

  type lca_error =
    [ `Max_depth_reached
    | `Too_many_lcas ]

  type ff_error =
    [ `Max_depth_reached
    | `No_change
    | `Rejected
    | `Too_many_lcas ]

  module Repo : sig
    type t = repo

    val v : Irmin.config -> t Lwt.t

    val heads : t -> commit list Lwt.t

    val branches : t -> branch list Lwt.t

    val export :
      ?full:bool ->
      ?depth:int ->
      ?min:commit list ->
      ?max:commit list ->
      t ->
      slice Lwt.t

    val import : t -> slice -> (metadata, [`Msg of branch]) result Lwt.t
  end

  val empty : repo -> t Lwt.t

  val master : repo -> t Lwt.t

  val of_branch : repo -> branch -> t Lwt.t

  val of_commit : commit -> t Lwt.t

  val repo : t -> repo

  val tree : t -> tree Lwt.t

  module Status : sig
    type t =
      [ `Branch of branch
      | `Commit of commit
      | `Empty ]

    val t : repo -> t Irmin.Type.ty

    val pp : t Fmt.t
  end

  val status : t -> Status.t

  module Head : sig
    val list : repo -> commit list Lwt.t

    val find : t -> commit option Lwt.t

    val get : t -> commit Lwt.t

    val set : t -> commit -> metadata Lwt.t

    val fast_forward :
      t ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      ( metadata,
        [`Max_depth_reached | `No_change | `Rejected | `Too_many_lcas] )
      result
      Lwt.t

    val test_and_set :
      t -> test:commit option -> set:commit option -> bool Lwt.t

    val merge :
      into:t ->
      info:Irmin.Info.f ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      (metadata, Irmin.Merge.conflict) result Lwt.t
  end

  module Commit : sig
    type t = commit

    val t : repo -> t Irmin.Type.ty

    val pp_hash : t Fmt.t

    val v : repo -> info:Irmin.Info.t -> parents:t list -> tree -> t Lwt.t

    val tree : t -> tree Lwt.t

    val parents : t -> t list Lwt.t

    val info : t -> Irmin.Info.t

    module Hash : sig
      type t = Irmin.Hash.SHA1.t

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : t -> hash

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Contents : sig
    type t = contents

    val t : t Irmin.Type.ty

    val merge : t option Irmin.Merge.t

    module Hash : sig
      type t = Commit.hash

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : repo -> t -> hash Lwt.t

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Tree : sig
    val empty : tree

    val of_contents : ?metadata:metadata -> contents -> tree

    val of_node : node -> tree

    val kind : tree -> key -> [`Contents | `Node] option Lwt.t

    val list : tree -> key -> (branch * [`Contents | `Node]) list Lwt.t

    val diff :
      tree -> tree -> (key * (contents * metadata) Irmin.diff) list Lwt.t

    val mem : tree -> key -> bool Lwt.t

    val find_all : tree -> key -> (contents * metadata) option Lwt.t

    val find : tree -> key -> contents option Lwt.t

    val get_all : tree -> key -> (contents * metadata) Lwt.t

    val get : tree -> key -> contents Lwt.t

    val add : tree -> key -> ?metadata:metadata -> contents -> tree Lwt.t

    val remove : tree -> key -> tree Lwt.t

    val mem_tree : tree -> key -> bool Lwt.t

    val find_tree : tree -> key -> tree option Lwt.t

    val get_tree : tree -> key -> tree Lwt.t

    val add_tree : tree -> key -> tree -> tree Lwt.t

    val merge : tree Irmin.Merge.t

    val clear_caches : tree -> metadata

    type marks =
      Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
        (Irmin.Branch.String)
        (Irmin.Hash.SHA1)
      .Tree
      .marks

    val empty_marks : metadata -> marks

    type 'a force =
      [ `False of key -> 'a -> 'a Lwt.t
      | `True ]

    type uniq =
      [ `False
      | `Marks of marks
      | `True ]

    type 'a node_fn = key -> branch list -> 'a -> 'a Lwt.t

    val fold :
      ?force:'a force ->
      ?uniq:uniq ->
      ?pre:'a node_fn ->
      ?post:'a node_fn ->
      (key -> contents -> 'a -> 'a Lwt.t) ->
      tree ->
      'a ->
      'a Lwt.t

    type stats =
                Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)
                  (Irmin.Path.String_list)
                  (Irmin.Branch.String)
                  (Irmin.Hash.SHA1)
                .Tree
                .stats = {
      nodes : int;
      leafs : int;
      skips : int;
      depth : int;
      width : int
    }

    val pp_stats : stats Fmt.t

    val stats : ?force:bool -> tree -> stats Lwt.t

    type concrete =
      [ `Contents of contents * metadata
      | `Tree of (branch * concrete) list ]

    val of_concrete : concrete -> tree

    val to_concrete : tree -> concrete Lwt.t

    module Hash : sig
      type t = Contents.hash

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash =
      [ `Contents of Hash.t * metadata
      | `Node of Hash.t ]

    val hash_t : hash Irmin.Type.ty

    val hash : repo -> tree -> hash Lwt.t

    val of_hash : repo -> hash -> tree option Lwt.t
  end

  val kind : t -> key -> [`Contents | `Node] option Lwt.t

  val list : t -> key -> (branch * [`Contents | `Node]) list Lwt.t

  val mem : t -> key -> bool Lwt.t

  val mem_tree : t -> key -> bool Lwt.t

  val find_all : t -> key -> (contents * metadata) option Lwt.t

  val find : t -> key -> contents option Lwt.t

  val get_all : t -> key -> (contents * metadata) Lwt.t

  val get : t -> key -> contents Lwt.t

  val find_tree : t -> key -> tree option Lwt.t

  val get_tree : t -> key -> tree Lwt.t

  type 'a transaction =
    ?retries:int ->
    ?allow_empty:bool ->
    ?strategy:[`Merge_with_parent of commit | `Set | `Test_and_set] ->
    info:Irmin.Info.f ->
    'a ->
    metadata Lwt.t

  val with_tree : t -> key -> (tree option -> tree option Lwt.t) transaction

  val set : t -> key -> ?metadata:metadata -> contents transaction

  val set_tree : t -> key -> tree transaction

  val remove : t -> key transaction

  val clone : src:t -> dst:branch -> t Lwt.t

  type watch =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .watch

  val watch :
    t -> ?init:commit -> (commit Irmin.diff -> metadata Lwt.t) -> watch Lwt.t

  val watch_key :
    t ->
    key ->
    ?init:commit ->
    ((commit * tree) Irmin.diff -> metadata Lwt.t) ->
    watch Lwt.t

  val unwatch : watch -> metadata Lwt.t

  type 'a merge =
    info:Irmin.Info.f ->
    ?max_depth:int ->
    ?n:int ->
    'a ->
    (metadata, Irmin.Merge.conflict) result Lwt.t

  val merge : into:t -> t merge

  val merge_with_branch : t -> branch merge

  val merge_with_commit : t -> commit merge

  val lcas :
    ?max_depth:int ->
    ?n:int ->
    t ->
    t ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_branch :
    t ->
    ?max_depth:int ->
    ?n:int ->
    branch ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_commit :
    t ->
    ?max_depth:int ->
    ?n:int ->
    commit ->
    (commit list, lca_error) result Lwt.t

  module History : sig
    type t =
      Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
        (Irmin.Branch.String)
        (Irmin.Hash.SHA1)
      .History
      .t

    module V : sig
      type t = commit

      val compare : t -> t -> int

      val hash : t -> int

      val equal : t -> t -> bool

      type label =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .History
        .V
        .label

      val create : label -> t

      val label : t -> label
    end

    type vertex = commit

    module E : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .History
        .E
        .t

      val compare : t -> t -> int

      type vertex = commit

      val src : t -> vertex

      val dst : t -> vertex

      type label =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .History
        .E
        .label

      val create : vertex -> label -> vertex -> t

      val label : t -> label
    end

    type edge = E.t

    val is_directed : bool

    val is_empty : t -> bool

    val nb_vertex : t -> int

    val nb_edges : t -> int

    val out_degree : t -> vertex -> int

    val in_degree : t -> vertex -> int

    val mem_vertex : t -> vertex -> bool

    val mem_edge : t -> vertex -> vertex -> bool

    val mem_edge_e : t -> edge -> bool

    val find_edge : t -> vertex -> vertex -> edge

    val find_all_edges : t -> vertex -> vertex -> edge list

    val succ : t -> vertex -> vertex list

    val pred : t -> vertex -> vertex list

    val succ_e : t -> vertex -> edge list

    val pred_e : t -> vertex -> edge list

    val iter_vertex : (vertex -> metadata) -> t -> metadata

    val fold_vertex : (vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges : (vertex -> vertex -> metadata) -> t -> metadata

    val fold_edges : (vertex -> vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges_e : (edge -> metadata) -> t -> metadata

    val fold_edges_e : (edge -> 'a -> 'a) -> t -> 'a -> 'a

    val map_vertex : (vertex -> vertex) -> t -> t

    val iter_succ : (vertex -> metadata) -> t -> vertex -> metadata

    val iter_pred : (vertex -> metadata) -> t -> vertex -> metadata

    val fold_succ : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val fold_pred : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_succ_e : (edge -> metadata) -> t -> vertex -> metadata

    val fold_succ_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_pred_e : (edge -> metadata) -> t -> vertex -> metadata

    val fold_pred_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val empty : t

    val add_vertex : t -> vertex -> t

    val remove_vertex : t -> vertex -> t

    val add_edge : t -> vertex -> vertex -> t

    val add_edge_e : t -> edge -> t

    val remove_edge : t -> vertex -> vertex -> t

    val remove_edge_e : t -> edge -> t
  end

  val history :
    ?depth:int -> ?min:commit list -> ?max:commit list -> t -> History.t Lwt.t

  module Branch : sig
    val mem : repo -> branch -> bool Lwt.t

    val find : repo -> branch -> commit option Lwt.t

    val get : repo -> branch -> commit Lwt.t

    val set : repo -> branch -> commit -> metadata Lwt.t

    val remove : repo -> branch -> metadata Lwt.t

    val list : repo -> branch list Lwt.t

    val watch :
      repo ->
      branch ->
      ?init:commit ->
      (commit Irmin.diff -> metadata Lwt.t) ->
      watch Lwt.t

    val watch_all :
      repo ->
      ?init:(branch * commit) list ->
      (branch -> commit Irmin.diff -> metadata Lwt.t) ->
      watch Lwt.t

    type t = branch

    val t : t Irmin.Type.ty

    val master : t

    val is_valid : t -> bool
  end

  module Key : sig
    type t = key

    type step = branch

    val empty : t

    val v : step list -> t

    val is_empty : t -> bool

    val cons : step -> t -> t

    val rcons : t -> step -> t

    val decons : t -> (step * t) option

    val rdecons : t -> (t * step) option

    val map : t -> (step -> 'a) -> 'a list

    val t : t Irmin.Type.ty

    val step_t : step Irmin.Type.ty
  end

  module Metadata : sig
    type t = metadata

    val t : t Irmin.Type.ty

    val merge : t Irmin.Merge.t

    val default : t
  end

  val step_t : branch Irmin.Type.ty

  val key_t : key Irmin.Type.ty

  val metadata_t : metadata Irmin.Type.ty

  val contents_t : contents Irmin.Type.ty

  val node_t : node Irmin.Type.ty

  val tree_t : tree Irmin.Type.ty

  val commit_t : repo -> commit Irmin.Type.ty

  val branch_t : branch Irmin.Type.ty

  val slice_t : slice Irmin.Type.ty

  val kind_t : [`Contents | `Node] Irmin.Type.ty

  val lca_error_t : lca_error Irmin.Type.ty

  val ff_error_t : ff_error Irmin.Type.ty

  module Private : sig
    module Contents : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Contents
        .t

      type key = Contents.hash

      type value = contents

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        val t : t Irmin.Type.ty

        val merge : t option Irmin.Merge.t
      end
    end

    module Node : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Node
        .t

      type key = Contents.key

      type value =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Node
        .value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      module Path : sig
        type t = Key.t

        type step = branch

        val empty : t

        val v : step list -> t

        val is_empty : t -> bool

        val cons : step -> t -> t

        val rcons : t -> step -> t

        val decons : t -> (step * t) option

        val rdecons : t -> (t * step) option

        val map : t -> (step -> 'a) -> 'a list

        val t : t Irmin.Type.ty

        val step_t : step Irmin.Type.ty
      end

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Metadata : sig
        type t = metadata

        val t : t Irmin.Type.ty

        val merge : t Irmin.Merge.t

        val default : t
      end

      module Val : sig
        type t = value

        type metadata = unit

        type contents = key

        type node = contents

        type step = branch

        type value =
          [ `Contents of node * metadata
          | `Node of node ]

        val v : (step * value) list -> t

        val list : t -> (step * value) list

        val empty : t

        val is_empty : t -> bool

        val find : t -> step -> value option

        val update : t -> step -> value -> t

        val remove : t -> step -> t

        val t : t Irmin.Type.ty

        val metadata_t : metadata Irmin.Type.ty

        val contents_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty

        val step_t : step Irmin.Type.ty

        val value_t : value Irmin.Type.ty
      end

      module Contents : sig
        type t =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Node
          .Contents
          .t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Node
          .Contents
          .value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : branch -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Val : sig
          type t = value

          val t : t Irmin.Type.ty

          val merge : t option Irmin.Merge.t
        end
      end
    end

    module Commit : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Commit
        .t

      type key = Node.key

      type value =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Commit
        .value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> info:Irmin.Info.f -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        type commit = key

        type node = commit

        val v : info:Irmin.Info.t -> node:node -> parents:node list -> t

        val node : t -> node

        val parents : t -> node list

        val info : t -> Irmin.Info.t

        val t : t Irmin.Type.ty

        val commit_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty
      end

      module Node : sig
        type t =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Commit
          .Node
          .t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Commit
          .Node
          .value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        module Path : sig
          type t =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Path
            .t

          type step =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Path
            .step

          val empty : t

          val v : step list -> t

          val is_empty : t -> bool

          val cons : step -> t -> t

          val rcons : t -> step -> t

          val decons : t -> (step * t) option

          val rdecons : t -> (t * step) option

          val map : t -> (step -> 'a) -> 'a list

          val t : t Irmin.Type.ty

          val step_t : step Irmin.Type.ty
        end

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : branch -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Metadata : sig
          type t =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Metadata
            .t

          val t : t Irmin.Type.ty

          val merge : t Irmin.Merge.t

          val default : t
        end

        module Val : sig
          type t = value

          type metadata = Metadata.t

          type contents =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Val
            .contents

          type node = key

          type step = Path.step

          type value =
            [ `Contents of contents * metadata
            | `Node of node ]

          val v : (step * value) list -> t

          val list : t -> (step * value) list

          val empty : t

          val is_empty : t -> bool

          val find : t -> step -> value option

          val update : t -> step -> value -> t

          val remove : t -> step -> t

          val t : t Irmin.Type.ty

          val metadata_t : metadata Irmin.Type.ty

          val contents_t : contents Irmin.Type.ty

          val node_t : node Irmin.Type.ty

          val step_t : step Irmin.Type.ty

          val value_t : value Irmin.Type.ty
        end

        module Contents : sig
          type t =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Contents
            .t

          type key = Val.contents

          type value =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Contents
            .value

          val mem : t -> key -> bool Lwt.t

          val find : t -> key -> value option Lwt.t

          val add : t -> value -> key Lwt.t

          val merge : t -> key option Irmin.Merge.t

          module Key : sig
            type t = key

            val digest : branch -> t

            val hash : t -> int

            val digest_size : int

            val t : t Irmin.Type.ty
          end

          module Val : sig
            type t = value

            val t : t Irmin.Type.ty

            val merge : t option Irmin.Merge.t
          end
        end
      end
    end

    module Branch : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Branch
        .t

      type key = branch

      type value = Commit.key

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val set : t -> key -> value -> metadata Lwt.t

      val test_and_set :
        t -> key -> test:value option -> set:value option -> bool Lwt.t

      val remove : t -> key -> metadata Lwt.t

      type watch =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Branch
        .watch

      val watch :
        t ->
        ?init:(key * value) list ->
        (key -> value Irmin.diff -> metadata Lwt.t) ->
        watch Lwt.t

      val watch_key :
        t ->
        key ->
        ?init:value ->
        (value Irmin.diff -> metadata Lwt.t) ->
        watch Lwt.t

      val unwatch : t -> watch -> metadata Lwt.t

      val list : t -> key list Lwt.t

      module Key : sig
        type t = key

        val t : t Irmin.Type.ty

        val master : t

        val is_valid : t -> bool
      end

      module Val : sig
        type t = value

        val digest : key -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end
    end

    module Slice : sig
      type t = slice

      type contents = Branch.value * Contents.value

      type node = Branch.value * Node.value

      type commit = Branch.value * Commit.value

      type value =
        [ `Commit of commit
        | `Contents of contents
        | `Node of node ]

      val empty : metadata -> t Lwt.t

      val add : t -> value -> metadata Lwt.t

      val iter : t -> (value -> metadata Lwt.t) -> metadata Lwt.t

      val t : t Irmin.Type.ty

      val contents_t : contents Irmin.Type.ty

      val node_t : node Irmin.Type.ty

      val commit_t : commit Irmin.Type.ty

      val value_t : value Irmin.Type.ty
    end

    module Repo : sig
      type t = repo

      val v : Irmin.config -> t Lwt.t

      val contents_t : t -> Contents.t

      val node_t : t -> Node.t

      val commit_t : t -> Commit.t

      val branch_t : t -> Branch.t
    end

    module Sync : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Sync
        .t

      type commit = Branch.value

      type branch = step

      type endpoint =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Sync
        .endpoint

      val fetch :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        (commit, [`Msg of branch | `No_head | `Not_available]) result Lwt.t

      val push :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        ( metadata,
          [`Detached_head | `Msg of branch | `No_head | `Not_available] )
        result
        Lwt.t

      val v : repo -> t Lwt.t
    end
  end

  type Irmin.remote += E of Private.Sync.endpoint

  val flush : DB.t -> int64 Lwt.t
end

module KV_git (DB : DB) : sig
  module DB : sig
    module Stor : Wodan.S

    type t = DB.t

    val db_root : t -> Stor.root

    val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

    val v : Irmin.config -> t Lwt.t

    val flush : t -> int64 Lwt.t
  end

  module AO (K : Irmin.Hash.S) (V : Irmin.Type.S) : sig
    type t = Irmin_chunk.AO_stable(LINK_BUILDER(DB))(AO_BUILDER(DB))(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val add : t -> value -> key Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  module RW (K : Irmin.Type.S) (V : Irmin.Type.S) : sig
    type t = RW_BUILDER(DB)(Irmin.Hash.SHA1)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val set : t -> key -> value -> unit Lwt.t

    val test_and_set :
      t -> key -> test:value option -> set:value option -> bool Lwt.t

    val remove : t -> key -> unit Lwt.t

    val list : t -> key list Lwt.t

    type watch = RW_BUILDER(DB)(Irmin.Hash.SHA1)(K)(V).watch

    val watch :
      t ->
      ?init:(key * value) list ->
      (key -> value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_key :
      t ->
      key ->
      ?init:value ->
      (value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val unwatch : t -> watch -> unit Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  type repo = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).repo

  type t = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).t

  type step = string

  type key = step list

  type metadata = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).metadata

  type contents = step

  type node = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).node

  type tree =
    [ `Contents of contents * metadata
    | `Node of node ]

  type commit = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).commit

  type branch = contents

  type slice = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).slice

  type lca_error =
    [ `Max_depth_reached
    | `Too_many_lcas ]

  type ff_error =
    [ `Max_depth_reached
    | `No_change
    | `Rejected
    | `Too_many_lcas ]

  module Repo : sig
    type t = repo

    val v : Irmin.config -> t Lwt.t

    val heads : t -> commit list Lwt.t

    val branches : t -> branch list Lwt.t

    val export :
      ?full:bool ->
      ?depth:int ->
      ?min:commit list ->
      ?max:commit list ->
      t ->
      slice Lwt.t

    val import : t -> slice -> (unit, [`Msg of branch]) result Lwt.t
  end

  val empty : repo -> t Lwt.t

  val master : repo -> t Lwt.t

  val of_branch : repo -> branch -> t Lwt.t

  val of_commit : commit -> t Lwt.t

  val repo : t -> repo

  val tree : t -> tree Lwt.t

  module Status : sig
    type t =
      [ `Branch of branch
      | `Commit of commit
      | `Empty ]

    val t : repo -> t Irmin.Type.ty

    val pp : t Fmt.t
  end

  val status : t -> Status.t

  module Head : sig
    val list : repo -> commit list Lwt.t

    val find : t -> commit option Lwt.t

    val get : t -> commit Lwt.t

    val set : t -> commit -> unit Lwt.t

    val fast_forward :
      t ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      ( unit,
        [`Max_depth_reached | `No_change | `Rejected | `Too_many_lcas] )
      result
      Lwt.t

    val test_and_set :
      t -> test:commit option -> set:commit option -> bool Lwt.t

    val merge :
      into:t ->
      info:Irmin.Info.f ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      (unit, Irmin.Merge.conflict) result Lwt.t
  end

  module Commit : sig
    type t = commit

    val t : repo -> t Irmin.Type.ty

    val pp_hash : t Fmt.t

    val v : repo -> info:Irmin.Info.t -> parents:t list -> tree -> t Lwt.t

    val tree : t -> tree Lwt.t

    val parents : t -> t list Lwt.t

    val info : t -> Irmin.Info.t

    module Hash : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Commit.Hash.t

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : t -> hash

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Contents : sig
    type t = branch

    val t : t Irmin.Type.ty

    val merge : t option Irmin.Merge.t

    module Hash : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Contents.Hash.t

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : repo -> t -> hash Lwt.t

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Tree : sig
    val empty : tree

    val of_contents : ?metadata:metadata -> branch -> tree

    val of_node : node -> tree

    val kind : tree -> key -> [`Contents | `Node] option Lwt.t

    val list : tree -> key -> (branch * [`Contents | `Node]) list Lwt.t

    val diff :
      tree -> tree -> (key * (branch * metadata) Irmin.diff) list Lwt.t

    val mem : tree -> key -> bool Lwt.t

    val find_all : tree -> key -> (branch * metadata) option Lwt.t

    val find : tree -> key -> branch option Lwt.t

    val get_all : tree -> key -> (branch * metadata) Lwt.t

    val get : tree -> key -> branch Lwt.t

    val add : tree -> key -> ?metadata:metadata -> branch -> tree Lwt.t

    val remove : tree -> key -> tree Lwt.t

    val mem_tree : tree -> key -> bool Lwt.t

    val find_tree : tree -> key -> tree option Lwt.t

    val get_tree : tree -> key -> tree Lwt.t

    val add_tree : tree -> key -> tree -> tree Lwt.t

    val merge : tree Irmin.Merge.t

    val clear_caches : tree -> unit

    type marks =
      Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Tree.marks

    val empty_marks : unit -> marks

    type 'a force =
      [ `False of key -> 'a -> 'a Lwt.t
      | `True ]

    type uniq =
      [ `False
      | `Marks of marks
      | `True ]

    type 'a node_fn = key -> branch list -> 'a -> 'a Lwt.t

    val fold :
      ?force:'a force ->
      ?uniq:uniq ->
      ?pre:'a node_fn ->
      ?post:'a node_fn ->
      (key -> branch -> 'a -> 'a Lwt.t) ->
      tree ->
      'a ->
      'a Lwt.t

    type stats =
                Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Tree.stats = {
      nodes : int;
      leafs : int;
      skips : int;
      depth : int;
      width : int
    }

    val pp_stats : stats Fmt.t

    val stats : ?force:bool -> tree -> stats Lwt.t

    type concrete =
      [ `Contents of branch * metadata
      | `Tree of (branch * concrete) list ]

    val of_concrete : concrete -> tree

    val to_concrete : tree -> concrete Lwt.t

    module Hash : sig
      type t = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Tree.Hash.t

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash =
      [ `Contents of Contents.hash * metadata
      | `Node of Hash.t ]

    val hash_t : hash Irmin.Type.ty

    val hash : repo -> tree -> hash Lwt.t

    val of_hash : repo -> hash -> tree option Lwt.t
  end

  val kind : t -> key -> [`Contents | `Node] option Lwt.t

  val list : t -> key -> (branch * [`Contents | `Node]) list Lwt.t

  val mem : t -> key -> bool Lwt.t

  val mem_tree : t -> key -> bool Lwt.t

  val find_all : t -> key -> (branch * metadata) option Lwt.t

  val find : t -> key -> branch option Lwt.t

  val get_all : t -> key -> (branch * metadata) Lwt.t

  val get : t -> key -> branch Lwt.t

  val find_tree : t -> key -> tree option Lwt.t

  val get_tree : t -> key -> tree Lwt.t

  type 'a transaction =
    ?retries:int ->
    ?allow_empty:bool ->
    ?strategy:[`Merge_with_parent of commit | `Set | `Test_and_set] ->
    info:Irmin.Info.f ->
    'a ->
    unit Lwt.t

  val with_tree : t -> key -> (tree option -> tree option Lwt.t) transaction

  val set : t -> key -> ?metadata:metadata -> branch transaction

  val set_tree : t -> key -> tree transaction

  val remove : t -> key transaction

  val clone : src:t -> dst:branch -> t Lwt.t

  type watch = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).watch

  val watch :
    t -> ?init:commit -> (commit Irmin.diff -> unit Lwt.t) -> watch Lwt.t

  val watch_key :
    t ->
    key ->
    ?init:commit ->
    ((commit * tree) Irmin.diff -> unit Lwt.t) ->
    watch Lwt.t

  val unwatch : watch -> unit Lwt.t

  type 'a merge =
    info:Irmin.Info.f ->
    ?max_depth:int ->
    ?n:int ->
    'a ->
    (unit, Irmin.Merge.conflict) result Lwt.t

  val merge : into:t -> t merge

  val merge_with_branch : t -> branch merge

  val merge_with_commit : t -> commit merge

  val lcas :
    ?max_depth:int ->
    ?n:int ->
    t ->
    t ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_branch :
    t ->
    ?max_depth:int ->
    ?n:int ->
    branch ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_commit :
    t ->
    ?max_depth:int ->
    ?n:int ->
    commit ->
    (commit list, lca_error) result Lwt.t

  module History : sig
    type t = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).History.t

    module V : sig
      type t = commit

      val compare : t -> t -> int

      val hash : t -> int

      val equal : t -> t -> bool

      type label =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).History.V.label

      val create : label -> t

      val label : t -> label
    end

    type vertex = commit

    module E : sig
      type t = Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).History.E.t

      val compare : t -> t -> int

      type vertex = commit

      val src : t -> vertex

      val dst : t -> vertex

      type label =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).History.E.label

      val create : vertex -> label -> vertex -> t

      val label : t -> label
    end

    type edge = E.t

    val is_directed : bool

    val is_empty : t -> bool

    val nb_vertex : t -> int

    val nb_edges : t -> int

    val out_degree : t -> vertex -> int

    val in_degree : t -> vertex -> int

    val mem_vertex : t -> vertex -> bool

    val mem_edge : t -> vertex -> vertex -> bool

    val mem_edge_e : t -> edge -> bool

    val find_edge : t -> vertex -> vertex -> edge

    val find_all_edges : t -> vertex -> vertex -> edge list

    val succ : t -> vertex -> vertex list

    val pred : t -> vertex -> vertex list

    val succ_e : t -> vertex -> edge list

    val pred_e : t -> vertex -> edge list

    val iter_vertex : (vertex -> unit) -> t -> unit

    val fold_vertex : (vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges : (vertex -> vertex -> unit) -> t -> unit

    val fold_edges : (vertex -> vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges_e : (edge -> unit) -> t -> unit

    val fold_edges_e : (edge -> 'a -> 'a) -> t -> 'a -> 'a

    val map_vertex : (vertex -> vertex) -> t -> t

    val iter_succ : (vertex -> unit) -> t -> vertex -> unit

    val iter_pred : (vertex -> unit) -> t -> vertex -> unit

    val fold_succ : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val fold_pred : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_succ_e : (edge -> unit) -> t -> vertex -> unit

    val fold_succ_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_pred_e : (edge -> unit) -> t -> vertex -> unit

    val fold_pred_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val empty : t

    val add_vertex : t -> vertex -> t

    val remove_vertex : t -> vertex -> t

    val add_edge : t -> vertex -> vertex -> t

    val add_edge_e : t -> edge -> t

    val remove_edge : t -> vertex -> vertex -> t

    val remove_edge_e : t -> edge -> t
  end

  val history :
    ?depth:int -> ?min:commit list -> ?max:commit list -> t -> History.t Lwt.t

  module Branch : sig
    val mem : repo -> branch -> bool Lwt.t

    val find : repo -> branch -> commit option Lwt.t

    val get : repo -> branch -> commit Lwt.t

    val set : repo -> branch -> commit -> unit Lwt.t

    val remove : repo -> branch -> unit Lwt.t

    val list : repo -> branch list Lwt.t

    val watch :
      repo ->
      branch ->
      ?init:commit ->
      (commit Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_all :
      repo ->
      ?init:(branch * commit) list ->
      (branch -> commit Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    type t = branch

    val t : t Irmin.Type.ty

    val master : t

    val is_valid : t -> bool
  end

  module Key : sig
    type t = key

    type step = branch

    val empty : t

    val v : step list -> t

    val is_empty : t -> bool

    val cons : step -> t -> t

    val rcons : t -> step -> t

    val decons : t -> (step * t) option

    val rdecons : t -> (t * step) option

    val map : t -> (step -> 'a) -> 'a list

    val t : t Irmin.Type.ty

    val step_t : step Irmin.Type.ty
  end

  module Metadata : sig
    type t = metadata

    val t : t Irmin.Type.ty

    val merge : t Irmin.Merge.t

    val default : t
  end

  val step_t : branch Irmin.Type.ty

  val key_t : key Irmin.Type.ty

  val metadata_t : metadata Irmin.Type.ty

  val contents_t : branch Irmin.Type.ty

  val node_t : node Irmin.Type.ty

  val tree_t : tree Irmin.Type.ty

  val commit_t : repo -> commit Irmin.Type.ty

  val branch_t : branch Irmin.Type.ty

  val slice_t : slice Irmin.Type.ty

  val kind_t : [`Contents | `Node] Irmin.Type.ty

  val lca_error_t : lca_error Irmin.Type.ty

  val ff_error_t : ff_error Irmin.Type.ty

  module Private : sig
    module Contents : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Contents.t

      type key = Contents.hash

      type value = branch

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : value -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        val t : t Irmin.Type.ty

        val merge : t option Irmin.Merge.t
      end
    end

    module Node : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Node.t

      type key = Tree.Hash.t

      type value =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Node.value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      module Path : sig
        type t = Key.t

        type step = branch

        val empty : t

        val v : step list -> t

        val is_empty : t -> bool

        val cons : step -> t -> t

        val rcons : t -> step -> t

        val decons : t -> (step * t) option

        val rdecons : t -> (t * step) option

        val map : t -> (step -> 'a) -> 'a list

        val t : t Irmin.Type.ty

        val step_t : step Irmin.Type.ty
      end

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Metadata : sig
        type t = metadata

        val t : t Irmin.Type.ty

        val merge : t Irmin.Merge.t

        val default : t
      end

      module Val : sig
        type t = value

        type metadata = Metadata.t

        type contents = Contents.key

        type node = key

        type step = branch

        type value =
          [ `Contents of contents * metadata
          | `Node of node ]

        val v : (step * value) list -> t

        val list : t -> (step * value) list

        val empty : t

        val is_empty : t -> bool

        val find : t -> step -> value option

        val update : t -> step -> value -> t

        val remove : t -> step -> t

        val t : t Irmin.Type.ty

        val metadata_t : metadata Irmin.Type.ty

        val contents_t : contents Irmin.Type.ty

        val node_t : node Irmin.Type.ty

        val step_t : step Irmin.Type.ty

        val value_t : value Irmin.Type.ty
      end

      module Contents : sig
        type t =
          Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Node
          .Contents
          .t

        type key = Val.contents

        type value =
          Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Node
          .Contents
          .value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : branch -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Val : sig
          type t = value

          val t : t Irmin.Type.ty

          val merge : t option Irmin.Merge.t
        end
      end
    end

    module Commit : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit.t

      type key = Commit.hash

      type value =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
        .value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> info:Irmin.Info.f -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        type commit = key

        type node = Node.key

        val v : info:Irmin.Info.t -> node:node -> parents:commit list -> t

        val node : t -> node

        val parents : t -> commit list

        val info : t -> Irmin.Info.t

        val t : t Irmin.Type.ty

        val commit_t : commit Irmin.Type.ty

        val node_t : node Irmin.Type.ty
      end

      module Node : sig
        type t =
          Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
          .Node
          .t

        type key = Val.node

        type value =
          Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
          .Node
          .value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        module Path : sig
          type t =
            Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
            .Node
            .Path
            .t

          type step =
            Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
            .Node
            .Path
            .step

          val empty : t

          val v : step list -> t

          val is_empty : t -> bool

          val cons : step -> t -> t

          val rcons : t -> step -> t

          val decons : t -> (step * t) option

          val rdecons : t -> (t * step) option

          val map : t -> (step -> 'a) -> 'a list

          val t : t Irmin.Type.ty

          val step_t : step Irmin.Type.ty
        end

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : branch -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Metadata : sig
          type t =
            Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
            .Node
            .Metadata
            .t

          val t : t Irmin.Type.ty

          val merge : t Irmin.Merge.t

          val default : t
        end

        module Val : sig
          type t = value

          type metadata = Metadata.t

          type contents =
            Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
            .Node
            .Val
            .contents

          type node = key

          type step = Path.step

          type value =
            [ `Contents of contents * metadata
            | `Node of node ]

          val v : (step * value) list -> t

          val list : t -> (step * value) list

          val empty : t

          val is_empty : t -> bool

          val find : t -> step -> value option

          val update : t -> step -> value -> t

          val remove : t -> step -> t

          val t : t Irmin.Type.ty

          val metadata_t : metadata Irmin.Type.ty

          val contents_t : contents Irmin.Type.ty

          val node_t : node Irmin.Type.ty

          val step_t : step Irmin.Type.ty

          val value_t : value Irmin.Type.ty
        end

        module Contents : sig
          type t =
            Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
            .Node
            .Contents
            .t

          type key = Val.contents

          type value =
            Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Commit
            .Node
            .Contents
            .value

          val mem : t -> key -> bool Lwt.t

          val find : t -> key -> value option Lwt.t

          val add : t -> value -> key Lwt.t

          val merge : t -> key option Irmin.Merge.t

          module Key : sig
            type t = key

            val digest : branch -> t

            val hash : t -> int

            val digest_size : int

            val t : t Irmin.Type.ty
          end

          module Val : sig
            type t = value

            val t : t Irmin.Type.ty

            val merge : t option Irmin.Merge.t
          end
        end
      end
    end

    module Branch : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Branch.t

      type key = branch

      type value = Commit.key

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val set : t -> key -> value -> unit Lwt.t

      val test_and_set :
        t -> key -> test:value option -> set:value option -> bool Lwt.t

      val remove : t -> key -> unit Lwt.t

      type watch =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Branch
        .watch

      val watch :
        t ->
        ?init:(key * value) list ->
        (key -> value Irmin.diff -> unit Lwt.t) ->
        watch Lwt.t

      val watch_key :
        t ->
        key ->
        ?init:value ->
        (value Irmin.diff -> unit Lwt.t) ->
        watch Lwt.t

      val unwatch : t -> watch -> unit Lwt.t

      val list : t -> key list Lwt.t

      module Key : sig
        type t = key

        val t : t Irmin.Type.ty

        val master : t

        val is_valid : t -> bool
      end

      module Val : sig
        type t = value

        val digest : key -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end
    end

    module Slice : sig
      type t = slice

      type contents = Contents.key * branch

      type node = Node.key * Node.value

      type commit = Branch.value * Commit.value

      type value =
        [ `Commit of commit
        | `Contents of contents
        | `Node of node ]

      val empty : unit -> t Lwt.t

      val add : t -> value -> unit Lwt.t

      val iter : t -> (value -> unit Lwt.t) -> unit Lwt.t

      val t : t Irmin.Type.ty

      val contents_t : contents Irmin.Type.ty

      val node_t : node Irmin.Type.ty

      val commit_t : commit Irmin.Type.ty

      val value_t : value Irmin.Type.ty
    end

    module Repo : sig
      type t = repo

      val v : Irmin.config -> t Lwt.t

      val contents_t : t -> Contents.t

      val node_t : t -> Node.t

      val commit_t : t -> Commit.t

      val branch_t : t -> Branch.t
    end

    module Sync : sig
      type t =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Sync.t

      type commit = Branch.value

      type branch = contents

      type endpoint =
        Irmin_git.Generic_KV(AO)(RW)(Irmin.Contents.String).Private.Sync
        .endpoint

      val fetch :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        (commit, [`Msg of branch | `No_head | `Not_available]) result Lwt.t

      val push :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        ( unit,
          [`Detached_head | `Msg of branch | `No_head | `Not_available] )
        result
        Lwt.t

      val v : repo -> t Lwt.t
    end
  end

  type Irmin.remote += E of Private.Sync.endpoint

  val flush : DB.t -> int64 Lwt.t
end

module KV_chunked (DB : DB) (C : Irmin.Contents.S) : sig
  module AO (K : Irmin.Hash.S) (V : Irmin.Type.S) : sig
    type t = Irmin_chunk.AO(AO_BUILDER(DB))(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val add : t -> value -> key Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  module DB : sig
    module Stor : Wodan.S

    type t = DB.t

    val db_root : t -> Stor.root

    val may_autoflush : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

    val v : Irmin.config -> t Lwt.t

    val flush : t -> int64 Lwt.t
  end

  module RW (K : Irmin.Type.S) (V : Irmin.Type.S) : sig
    type t = RW_BUILDER(DB)(Irmin.Hash.SHA1)(K)(V).t

    type key = K.t

    type value = V.t

    val mem : t -> key -> bool Lwt.t

    val find : t -> key -> value option Lwt.t

    val set : t -> key -> value -> unit Lwt.t

    val test_and_set :
      t -> key -> test:value option -> set:value option -> bool Lwt.t

    val remove : t -> key -> unit Lwt.t

    val list : t -> key list Lwt.t

    type watch = RW_BUILDER(DB)(Irmin.Hash.SHA1)(K)(V).watch

    val watch :
      t ->
      ?init:(key * value) list ->
      (key -> value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val watch_key :
      t ->
      key ->
      ?init:value ->
      (value Irmin.diff -> unit Lwt.t) ->
      watch Lwt.t

    val unwatch : t -> watch -> unit Lwt.t

    val v : Irmin.config -> t Lwt.t
  end

  type repo =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .repo

  type t =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .t

  type step = string

  type key = Irmin.Path.String_list.t

  type metadata = unit

  type contents = C.t

  type node =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .node

  type tree =
    [ `Contents of contents * metadata
    | `Node of node ]

  type commit =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .commit

  type branch = step

  type slice =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .slice

  type lca_error =
    [ `Max_depth_reached
    | `Too_many_lcas ]

  type ff_error =
    [ `Max_depth_reached
    | `No_change
    | `Rejected
    | `Too_many_lcas ]

  module Repo : sig
    type t = repo

    val v : Irmin.config -> t Lwt.t

    val heads : t -> commit list Lwt.t

    val branches : t -> branch list Lwt.t

    val export :
      ?full:bool ->
      ?depth:int ->
      ?min:commit list ->
      ?max:commit list ->
      t ->
      slice Lwt.t

    val import : t -> slice -> (metadata, [`Msg of branch]) result Lwt.t
  end

  val empty : repo -> t Lwt.t

  val master : repo -> t Lwt.t

  val of_branch : repo -> branch -> t Lwt.t

  val of_commit : commit -> t Lwt.t

  val repo : t -> repo

  val tree : t -> tree Lwt.t

  module Status : sig
    type t =
      [ `Branch of branch
      | `Commit of commit
      | `Empty ]

    val t : repo -> t Irmin.Type.ty

    val pp : t Fmt.t
  end

  val status : t -> Status.t

  module Head : sig
    val list : repo -> commit list Lwt.t

    val find : t -> commit option Lwt.t

    val get : t -> commit Lwt.t

    val set : t -> commit -> metadata Lwt.t

    val fast_forward :
      t ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      ( metadata,
        [`Max_depth_reached | `No_change | `Rejected | `Too_many_lcas] )
      result
      Lwt.t

    val test_and_set :
      t -> test:commit option -> set:commit option -> bool Lwt.t

    val merge :
      into:t ->
      info:Irmin.Info.f ->
      ?max_depth:int ->
      ?n:int ->
      commit ->
      (metadata, Irmin.Merge.conflict) result Lwt.t
  end

  module Commit : sig
    type t = commit

    val t : repo -> t Irmin.Type.ty

    val pp_hash : t Fmt.t

    val v : repo -> info:Irmin.Info.t -> parents:t list -> tree -> t Lwt.t

    val tree : t -> tree Lwt.t

    val parents : t -> t list Lwt.t

    val info : t -> Irmin.Info.t

    module Hash : sig
      type t = Irmin.Hash.SHA1.t

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : t -> hash

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Contents : sig
    type t = contents

    val t : t Irmin.Type.ty

    val merge : t option Irmin.Merge.t

    module Hash : sig
      type t = Commit.hash

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash = Hash.t

    val hash : repo -> t -> hash Lwt.t

    val of_hash : repo -> hash -> t option Lwt.t
  end

  module Tree : sig
    val empty : tree

    val of_contents : ?metadata:metadata -> contents -> tree

    val of_node : node -> tree

    val kind : tree -> key -> [`Contents | `Node] option Lwt.t

    val list : tree -> key -> (branch * [`Contents | `Node]) list Lwt.t

    val diff :
      tree -> tree -> (key * (contents * metadata) Irmin.diff) list Lwt.t

    val mem : tree -> key -> bool Lwt.t

    val find_all : tree -> key -> (contents * metadata) option Lwt.t

    val find : tree -> key -> contents option Lwt.t

    val get_all : tree -> key -> (contents * metadata) Lwt.t

    val get : tree -> key -> contents Lwt.t

    val add : tree -> key -> ?metadata:metadata -> contents -> tree Lwt.t

    val remove : tree -> key -> tree Lwt.t

    val mem_tree : tree -> key -> bool Lwt.t

    val find_tree : tree -> key -> tree option Lwt.t

    val get_tree : tree -> key -> tree Lwt.t

    val add_tree : tree -> key -> tree -> tree Lwt.t

    val merge : tree Irmin.Merge.t

    val clear_caches : tree -> metadata

    type marks =
      Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
        (Irmin.Branch.String)
        (Irmin.Hash.SHA1)
      .Tree
      .marks

    val empty_marks : metadata -> marks

    type 'a force =
      [ `False of key -> 'a -> 'a Lwt.t
      | `True ]

    type uniq =
      [ `False
      | `Marks of marks
      | `True ]

    type 'a node_fn = key -> branch list -> 'a -> 'a Lwt.t

    val fold :
      ?force:'a force ->
      ?uniq:uniq ->
      ?pre:'a node_fn ->
      ?post:'a node_fn ->
      (key -> contents -> 'a -> 'a Lwt.t) ->
      tree ->
      'a ->
      'a Lwt.t

    type stats =
                Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)
                  (Irmin.Path.String_list)
                  (Irmin.Branch.String)
                  (Irmin.Hash.SHA1)
                .Tree
                .stats = {
      nodes : int;
      leafs : int;
      skips : int;
      depth : int;
      width : int
    }

    val pp_stats : stats Fmt.t

    val stats : ?force:bool -> tree -> stats Lwt.t

    type concrete =
      [ `Contents of contents * metadata
      | `Tree of (branch * concrete) list ]

    val of_concrete : concrete -> tree

    val to_concrete : tree -> concrete Lwt.t

    module Hash : sig
      type t = Contents.hash

      val digest : branch -> t

      val hash : t -> int

      val digest_size : int

      val t : t Irmin.Type.ty
    end

    type hash =
      [ `Contents of Hash.t * metadata
      | `Node of Hash.t ]

    val hash_t : hash Irmin.Type.ty

    val hash : repo -> tree -> hash Lwt.t

    val of_hash : repo -> hash -> tree option Lwt.t
  end

  val kind : t -> key -> [`Contents | `Node] option Lwt.t

  val list : t -> key -> (branch * [`Contents | `Node]) list Lwt.t

  val mem : t -> key -> bool Lwt.t

  val mem_tree : t -> key -> bool Lwt.t

  val find_all : t -> key -> (contents * metadata) option Lwt.t

  val find : t -> key -> contents option Lwt.t

  val get_all : t -> key -> (contents * metadata) Lwt.t

  val get : t -> key -> contents Lwt.t

  val find_tree : t -> key -> tree option Lwt.t

  val get_tree : t -> key -> tree Lwt.t

  type 'a transaction =
    ?retries:int ->
    ?allow_empty:bool ->
    ?strategy:[`Merge_with_parent of commit | `Set | `Test_and_set] ->
    info:Irmin.Info.f ->
    'a ->
    metadata Lwt.t

  val with_tree : t -> key -> (tree option -> tree option Lwt.t) transaction

  val set : t -> key -> ?metadata:metadata -> contents transaction

  val set_tree : t -> key -> tree transaction

  val remove : t -> key transaction

  val clone : src:t -> dst:branch -> t Lwt.t

  type watch =
    Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
      (Irmin.Branch.String)
      (Irmin.Hash.SHA1)
    .watch

  val watch :
    t -> ?init:commit -> (commit Irmin.diff -> metadata Lwt.t) -> watch Lwt.t

  val watch_key :
    t ->
    key ->
    ?init:commit ->
    ((commit * tree) Irmin.diff -> metadata Lwt.t) ->
    watch Lwt.t

  val unwatch : watch -> metadata Lwt.t

  type 'a merge =
    info:Irmin.Info.f ->
    ?max_depth:int ->
    ?n:int ->
    'a ->
    (metadata, Irmin.Merge.conflict) result Lwt.t

  val merge : into:t -> t merge

  val merge_with_branch : t -> branch merge

  val merge_with_commit : t -> commit merge

  val lcas :
    ?max_depth:int ->
    ?n:int ->
    t ->
    t ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_branch :
    t ->
    ?max_depth:int ->
    ?n:int ->
    branch ->
    (commit list, lca_error) result Lwt.t

  val lcas_with_commit :
    t ->
    ?max_depth:int ->
    ?n:int ->
    commit ->
    (commit list, lca_error) result Lwt.t

  module History : sig
    type t =
      Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
        (Irmin.Branch.String)
        (Irmin.Hash.SHA1)
      .History
      .t

    module V : sig
      type t = commit

      val compare : t -> t -> int

      val hash : t -> int

      val equal : t -> t -> bool

      type label =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .History
        .V
        .label

      val create : label -> t

      val label : t -> label
    end

    type vertex = commit

    module E : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .History
        .E
        .t

      val compare : t -> t -> int

      type vertex = commit

      val src : t -> vertex

      val dst : t -> vertex

      type label =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .History
        .E
        .label

      val create : vertex -> label -> vertex -> t

      val label : t -> label
    end

    type edge = E.t

    val is_directed : bool

    val is_empty : t -> bool

    val nb_vertex : t -> int

    val nb_edges : t -> int

    val out_degree : t -> vertex -> int

    val in_degree : t -> vertex -> int

    val mem_vertex : t -> vertex -> bool

    val mem_edge : t -> vertex -> vertex -> bool

    val mem_edge_e : t -> edge -> bool

    val find_edge : t -> vertex -> vertex -> edge

    val find_all_edges : t -> vertex -> vertex -> edge list

    val succ : t -> vertex -> vertex list

    val pred : t -> vertex -> vertex list

    val succ_e : t -> vertex -> edge list

    val pred_e : t -> vertex -> edge list

    val iter_vertex : (vertex -> metadata) -> t -> metadata

    val fold_vertex : (vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges : (vertex -> vertex -> metadata) -> t -> metadata

    val fold_edges : (vertex -> vertex -> 'a -> 'a) -> t -> 'a -> 'a

    val iter_edges_e : (edge -> metadata) -> t -> metadata

    val fold_edges_e : (edge -> 'a -> 'a) -> t -> 'a -> 'a

    val map_vertex : (vertex -> vertex) -> t -> t

    val iter_succ : (vertex -> metadata) -> t -> vertex -> metadata

    val iter_pred : (vertex -> metadata) -> t -> vertex -> metadata

    val fold_succ : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val fold_pred : (vertex -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_succ_e : (edge -> metadata) -> t -> vertex -> metadata

    val fold_succ_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val iter_pred_e : (edge -> metadata) -> t -> vertex -> metadata

    val fold_pred_e : (edge -> 'a -> 'a) -> t -> vertex -> 'a -> 'a

    val empty : t

    val add_vertex : t -> vertex -> t

    val remove_vertex : t -> vertex -> t

    val add_edge : t -> vertex -> vertex -> t

    val add_edge_e : t -> edge -> t

    val remove_edge : t -> vertex -> vertex -> t

    val remove_edge_e : t -> edge -> t
  end

  val history :
    ?depth:int -> ?min:commit list -> ?max:commit list -> t -> History.t Lwt.t

  module Branch : sig
    val mem : repo -> branch -> bool Lwt.t

    val find : repo -> branch -> commit option Lwt.t

    val get : repo -> branch -> commit Lwt.t

    val set : repo -> branch -> commit -> metadata Lwt.t

    val remove : repo -> branch -> metadata Lwt.t

    val list : repo -> branch list Lwt.t

    val watch :
      repo ->
      branch ->
      ?init:commit ->
      (commit Irmin.diff -> metadata Lwt.t) ->
      watch Lwt.t

    val watch_all :
      repo ->
      ?init:(branch * commit) list ->
      (branch -> commit Irmin.diff -> metadata Lwt.t) ->
      watch Lwt.t

    type t = branch

    val t : t Irmin.Type.ty

    val master : t

    val is_valid : t -> bool
  end

  module Key : sig
    type t = key

    type step = branch

    val empty : t

    val v : step list -> t

    val is_empty : t -> bool

    val cons : step -> t -> t

    val rcons : t -> step -> t

    val decons : t -> (step * t) option

    val rdecons : t -> (t * step) option

    val map : t -> (step -> 'a) -> 'a list

    val t : t Irmin.Type.ty

    val step_t : step Irmin.Type.ty
  end

  module Metadata : sig
    type t = metadata

    val t : t Irmin.Type.ty

    val merge : t Irmin.Merge.t

    val default : t
  end

  val step_t : branch Irmin.Type.ty

  val key_t : key Irmin.Type.ty

  val metadata_t : metadata Irmin.Type.ty

  val contents_t : contents Irmin.Type.ty

  val node_t : node Irmin.Type.ty

  val tree_t : tree Irmin.Type.ty

  val commit_t : repo -> commit Irmin.Type.ty

  val branch_t : branch Irmin.Type.ty

  val slice_t : slice Irmin.Type.ty

  val kind_t : [`Contents | `Node] Irmin.Type.ty

  val lca_error_t : lca_error Irmin.Type.ty

  val ff_error_t : ff_error Irmin.Type.ty

  module Private : sig
    module Contents : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Contents
        .t

      type key = Contents.hash

      type value = contents

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        val t : t Irmin.Type.ty

        val merge : t option Irmin.Merge.t
      end
    end

    module Node : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Node
        .t

      type key = Contents.key

      type value =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Node
        .value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      module Path : sig
        type t = Key.t

        type step = branch

        val empty : t

        val v : step list -> t

        val is_empty : t -> bool

        val cons : step -> t -> t

        val rcons : t -> step -> t

        val decons : t -> (step * t) option

        val rdecons : t -> (t * step) option

        val map : t -> (step -> 'a) -> 'a list

        val t : t Irmin.Type.ty

        val step_t : step Irmin.Type.ty
      end

      val merge : t -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Metadata : sig
        type t = metadata

        val t : t Irmin.Type.ty

        val merge : t Irmin.Merge.t

        val default : t
      end

      module Val : sig
        type t = value

        type metadata = unit

        type contents = key

        type node = contents

        type step = branch

        type value =
          [ `Contents of node * metadata
          | `Node of node ]

        val v : (step * value) list -> t

        val list : t -> (step * value) list

        val empty : t

        val is_empty : t -> bool

        val find : t -> step -> value option

        val update : t -> step -> value -> t

        val remove : t -> step -> t

        val t : t Irmin.Type.ty

        val metadata_t : metadata Irmin.Type.ty

        val contents_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty

        val step_t : step Irmin.Type.ty

        val value_t : value Irmin.Type.ty
      end

      module Contents : sig
        type t =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Node
          .Contents
          .t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Node
          .Contents
          .value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : branch -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Val : sig
          type t = value

          val t : t Irmin.Type.ty

          val merge : t option Irmin.Merge.t
        end
      end
    end

    module Commit : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Commit
        .t

      type key = Node.key

      type value =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Commit
        .value

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val add : t -> value -> key Lwt.t

      val merge : t -> info:Irmin.Info.f -> key option Irmin.Merge.t

      module Key : sig
        type t = key

        val digest : branch -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end

      module Val : sig
        type t = value

        type commit = key

        type node = commit

        val v : info:Irmin.Info.t -> node:node -> parents:node list -> t

        val node : t -> node

        val parents : t -> node list

        val info : t -> Irmin.Info.t

        val t : t Irmin.Type.ty

        val commit_t : node Irmin.Type.ty

        val node_t : node Irmin.Type.ty
      end

      module Node : sig
        type t =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Commit
          .Node
          .t

        type key = Val.node

        type value =
          Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
            (Irmin.Branch.String)
            (Irmin.Hash.SHA1)
          .Private
          .Commit
          .Node
          .value

        val mem : t -> key -> bool Lwt.t

        val find : t -> key -> value option Lwt.t

        val add : t -> value -> key Lwt.t

        module Path : sig
          type t =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Path
            .t

          type step =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Path
            .step

          val empty : t

          val v : step list -> t

          val is_empty : t -> bool

          val cons : step -> t -> t

          val rcons : t -> step -> t

          val decons : t -> (step * t) option

          val rdecons : t -> (t * step) option

          val map : t -> (step -> 'a) -> 'a list

          val t : t Irmin.Type.ty

          val step_t : step Irmin.Type.ty
        end

        val merge : t -> key option Irmin.Merge.t

        module Key : sig
          type t = key

          val digest : branch -> t

          val hash : t -> int

          val digest_size : int

          val t : t Irmin.Type.ty
        end

        module Metadata : sig
          type t =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Metadata
            .t

          val t : t Irmin.Type.ty

          val merge : t Irmin.Merge.t

          val default : t
        end

        module Val : sig
          type t = value

          type metadata = Metadata.t

          type contents =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Val
            .contents

          type node = key

          type step = Path.step

          type value =
            [ `Contents of contents * metadata
            | `Node of node ]

          val v : (step * value) list -> t

          val list : t -> (step * value) list

          val empty : t

          val is_empty : t -> bool

          val find : t -> step -> value option

          val update : t -> step -> value -> t

          val remove : t -> step -> t

          val t : t Irmin.Type.ty

          val metadata_t : metadata Irmin.Type.ty

          val contents_t : contents Irmin.Type.ty

          val node_t : node Irmin.Type.ty

          val step_t : step Irmin.Type.ty

          val value_t : value Irmin.Type.ty
        end

        module Contents : sig
          type t =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Contents
            .t

          type key = Val.contents

          type value =
            Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
              (Irmin.Branch.String)
              (Irmin.Hash.SHA1)
            .Private
            .Commit
            .Node
            .Contents
            .value

          val mem : t -> key -> bool Lwt.t

          val find : t -> key -> value option Lwt.t

          val add : t -> value -> key Lwt.t

          val merge : t -> key option Irmin.Merge.t

          module Key : sig
            type t = key

            val digest : branch -> t

            val hash : t -> int

            val digest_size : int

            val t : t Irmin.Type.ty
          end

          module Val : sig
            type t = value

            val t : t Irmin.Type.ty

            val merge : t option Irmin.Merge.t
          end
        end
      end
    end

    module Branch : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Branch
        .t

      type key = branch

      type value = Commit.key

      val mem : t -> key -> bool Lwt.t

      val find : t -> key -> value option Lwt.t

      val set : t -> key -> value -> metadata Lwt.t

      val test_and_set :
        t -> key -> test:value option -> set:value option -> bool Lwt.t

      val remove : t -> key -> metadata Lwt.t

      type watch =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Branch
        .watch

      val watch :
        t ->
        ?init:(key * value) list ->
        (key -> value Irmin.diff -> metadata Lwt.t) ->
        watch Lwt.t

      val watch_key :
        t ->
        key ->
        ?init:value ->
        (value Irmin.diff -> metadata Lwt.t) ->
        watch Lwt.t

      val unwatch : t -> watch -> metadata Lwt.t

      val list : t -> key list Lwt.t

      module Key : sig
        type t = key

        val t : t Irmin.Type.ty

        val master : t

        val is_valid : t -> bool
      end

      module Val : sig
        type t = value

        val digest : key -> t

        val hash : t -> int

        val digest_size : int

        val t : t Irmin.Type.ty
      end
    end

    module Slice : sig
      type t = slice

      type contents = Branch.value * Contents.value

      type node = Branch.value * Node.value

      type commit = Branch.value * Commit.value

      type value =
        [ `Commit of commit
        | `Contents of contents
        | `Node of node ]

      val empty : metadata -> t Lwt.t

      val add : t -> value -> metadata Lwt.t

      val iter : t -> (value -> metadata Lwt.t) -> metadata Lwt.t

      val t : t Irmin.Type.ty

      val contents_t : contents Irmin.Type.ty

      val node_t : node Irmin.Type.ty

      val commit_t : commit Irmin.Type.ty

      val value_t : value Irmin.Type.ty
    end

    module Repo : sig
      type t = repo

      val v : Irmin.config -> t Lwt.t

      val contents_t : t -> Contents.t

      val node_t : t -> Node.t

      val commit_t : t -> Commit.t

      val branch_t : t -> Branch.t
    end

    module Sync : sig
      type t =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Sync
        .t

      type commit = Branch.value

      type branch = step

      type endpoint =
        Irmin.Make(AO)(RW)(Irmin.Metadata.None)(C)(Irmin.Path.String_list)
          (Irmin.Branch.String)
          (Irmin.Hash.SHA1)
        .Private
        .Sync
        .endpoint

      val fetch :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        (commit, [`Msg of branch | `No_head | `Not_available]) result Lwt.t

      val push :
        t ->
        ?depth:int ->
        endpoint ->
        branch ->
        ( metadata,
          [`Detached_head | `Msg of branch | `No_head | `Not_available] )
        result
        Lwt.t

      val v : repo -> t Lwt.t
    end
  end

  type Irmin.remote += E of Private.Sync.endpoint

  val flush : DB.t -> int64 Lwt.t
end
