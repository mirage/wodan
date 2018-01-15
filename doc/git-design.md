# Git design

```
module type KEY = sig
  type t
end

module type AO_CONTAINER = sig
  type t
  type handle = t * KEY.t

  val exists : handle -> bool
  val get : handle -> Cstruct.t
  val set : handle -> Cstruct.t -> unit
end

module type RW_CONTAINER = sig
  include AO_CONTAINER

  val delete : handle -> ()
  (* move is atomic *)
  val move : handle -> KEY.t -> ()
  val list : () -> KEY.t list
end

module type DELAYED_CONTAINER = sig
  include AO_CONTAINER
  type delayed_handle

  val open_ao : () -> delayed_handle
  val append : delayed_handle -> Cstruct.t -> ()
  val close : delayed_handle -> handle
end

module type HANDLE = sig
  type ref_handle = RW_CONTAINER.handle
  type object_handle = DELAYED_CONTAINER.handle
  type object_delayed_handle = DELAYED_CONTAINER.delayed_handle
  type pack_delayed_handle = DELAYED_CONTAINER.delayed_handle

  val ref : string -> ref_handle
  val object : hash -> object_handle
  val new_object : () -> object_delayed_handle
  val new_pack : () -> pack_delayed_handle
  (* commit is atomic *)
  val commit : () -> ()
end

```

The design doesn't include a scratch space as previous.
Instead, it features delayed objects, which are not named yet but can be appended to.
This is used when writing packfiles.
To implement delayed objects, the chunking layer is extended.

GC is not implemented currently.
To add it, we need a graph walker that copies objects recursively,
and a function that switches the filesystem between two partitions.

The object and packfile containers may perform autocommit to flush data to disk
when necessary.  This will not commit any incomplete delayed objects; partial
data may be written, but the root of the object won't be.
Closing a delayed object will write a Merkle tree indexing it.
The tree is built in memory by the chunking layer, but writing it is delayed
to avoid unnecessary churn.

