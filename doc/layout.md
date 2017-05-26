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
there is no longer a special type marker for leafs.
