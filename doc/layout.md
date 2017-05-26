# Layout

## The superblock

```
(* 512 bytes.  The rest of the block isn't crc-controlled. *)
[%%cstruct type superblock = {
  magic: uint8_t [@len 16];
  (* major version, all later fields may change if this does *)
  version: uint32_t;
  compat_flags: uint32_t;
  (* refuse to mount if unknown incompat_flags are set *)
  incompat_flags: uint32_t;
  block_size: uint32_t;
  (* TODO make this a per-tree setting *)
  key_size: uint8_t;
  first_block_written: uint64_t;
  logical_size: uint64_t;
  reserved: uint8_t [@len 459];
  crc: uint32_t;
}[@@little_endian]]
```

The focus is on managing compatibility.
This is written once at filesystem creation and never edited.

The magic string must be "MIRAGE KVFS \xf0\x9f\x90\xaa".

The major version must be 1.

Compat flags is currently empty, but may be added to without the
current implementation refusing to mount.

Incompat flags is currently empty, and adding to it will prevent
the current implementation from mounting.

The block size must match what is given to the parameters module.

First block written points to the first block ever written, and is
used to guide the bisection process that finds the newest root.

Logical size says how large the filesystem is.  Resizing is not supported.
The underlying device may grow, but the filesystem won't have any
accesses beyond this point.

Reserved data is currently zero, but adding to it won't break mounting.

The CRC controls the first 512 bytes.  The first block may be larger than
the superblock; the extra padding is like reserved data, currently
initialised to zero but won't break mounting.

The block size must be a strict multiple of the IO size.
The IO size must match the page size which is the unit
for direct IO, on platforms that require direct IO.
The IO size must be a strict multiple of the sector size,
the size at which writes are atomic, which must be a strict
multiple of 512.

## Node blocks

There are two types of nodes: root and child.
A leaf is a child that doesn't have children;
there is no longer a special type marker or a specific layout for leaves.

The focus is on compacity and the ability to grow logged data and child data
independently.

```
[%%cstruct type anynode_hdr = {
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]

[%%cstruct type rootnode_hdr = {
  (* nodetype = 1 *)
  nodetype: uint8_t;
  (* will this wrap? there's no uint128_t. Nah, flash will wear out first. *)
  generation: uint64_t;
  tree_id: uint32_t;
  next_tree_id: uint32_t;
  prev_tree: uint64_t;
}[@@little_endian]]
(* Contents: child node links, and logged data *)
(* All node types end with a CRC *)
(* rootnode_hdr
 * logged data: (key, datalen, data)*, grow from the left end towards the right
 *
 * separation: at least at redzone_size (the largest of a key or a uint64_t) of all zeroes
 * disambiguates from a valid logical offset on the right,
 * disambiguates from a valid key on the left.
 *
 * child links: (key, logical offset)*, grow from the right end towards the left
 * crc *)

[%%cstruct type childnode_hdr = {
  (* nodetype = 2 *)
  nodetype: uint8_t;
  generation: uint64_t;
}[@@little_endian]]
(* Contents: child node links, and logged data *)
(* Layout: see above *)
```

All nodes start with a node type and a generation number.

The generation number uniquely identifies a block and its contents
on disk.  When the content changes, a new block is written at
another location with a new, greater generation number.
Children are written before the parents that reference them.
When a node has children, their generation number is strictly
lower.  This prevents loops.

All nodes end with a CRC (CRC32C) controlling the whole block.

Root nodes (nodetype: 1) are tree roots.
The tree id identifies different trees; this will be used to
implement a metadata tree.  next_tree_id is the next available
tree id that will be used when the next tree is created.
prev_tree points to the root of the location of the previous tree,
building a circular list.

Child nodes have just the basic, generic header (nodetype, generation).

Node content is made of two packed lists, one that grows towards higher
addresses and contains logged data, one that grows towards lower addresses
from just before the CRC and contains child data.  The latter is empty in
leaf nodes.  The two lists are separated by a red zone, which is also present
in leaf nodes.  The redzone size is the minimum size of a child link and a logged
data item.

Logged data is made of contiguous logged items.  An item is a key followed
by a data size and the data itself (forming a length-prefixed, Pascal-style string).

Child data is made of contiguous child links.  A child link is a key followed
by the on-disk location of the child.
