# Wodan internals

config.ml is the standard MirageOS configuration file. It configures a test
client which runs over a generic storage implementation, either file-backed or
a ramdisk.

unikernel.ml contains the unikernel main method, which runs tests over the
storage API. The current tests exercise inserting, flushing, closing and
reopening the filesystem, in a random fashion.

storage.ml contains the storage implementation.

There are data structures and utility methods defined at the top level.

There are cstructs defined for the layout of different types of blocks:
superblock, root node or child node. Additionally, an anynode cstruct contains
the fields common to root and child nodes.

The main data structures are an LRU cache and LRU entries. These are the
in-memory representation of nodes. The nodes can be in various states of
indexing; either the child keys or the data keys can be indexed. This is
managed through lazy values. Some mass updates in the insert code can make data
keys lazy again. Child keys always stay materialized because they contain extra
metadata which isn't available in the cold representation of a node. The
childlink can contain an alloc id if the child has been loaded, which allows
navigating the live tree.

The main cache structure contains the LRU, a set of dirty roots, various
counters which are used to allocate sequential numbers, counters used to track
free space, a map of where free space is on the filesystem, other counters used
to track statistics.

The main module is a Make functor, which takes a block device and a set of
parameters that control data layout.

The API contains the verbs:

- prepare_io for opening a device. Takes flags for either formatting an empty
device, or opening an existing filesystem. This returns a set of filesystem
roots indexed by their root id. Roots are references to a filesystem root.

- insert for inserting data into a root. Currently deleting is done by
inserting a zero-sized value.

- lookup for reading the value associated with a key within a root.

- flush for landing pending data on the disk.

Opening the filesystem involves locating the root block (using a bisection that
looks for the highest generation number of a root), checking the filesystem,
and scanning the entirety of if to establish a free space map. This will be
improved by maintaining a space map as part of a secondary metadata root.

The implementation for insert is split into a half that reserves space, might
rebalance the tree, might load nodes from disk, and a fast half that
immediately inserts into already available space. The reserve implementation is
sometimes called to reserve space for a batch of fast inserts; this is the case
when a node spills into a lower node. This split allows better error reporting
when there is no free space.



