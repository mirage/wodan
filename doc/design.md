# Design notes

Notes about important choices in the filesystem and implementation design

## Caching

Caching is done at the block level.

### Cache priority

There's an LRU list that combines clean and dirty items.
Flushing dirty items doesn't bump them or discard them from the cache.
They become clean, their priority order stays the same.

### Hierarchical consistency

The LRU can't be arbitrarily reordered as usual;
we want it to preserve hierarchy, so that it only contains
subtrees of the main tree sharing the same root.

To do this, we make sure that a parent stays more recent than its child.
Order LRU calls properly, and require the LRU to have room for a few
paths from the tree root.

## Allocation and adressing cache items

All cache items are accessed through an AllocID. These IDs, strongly
typed to prevent some likely bugs, are pulled from an arbitrary sequence
started at mount time. Whenever a node is loaded or created, it gets an
AllocID, and when it is finally dropped from cache, that identifier
isn't reused. Since nodes are only ever accessed from one path (no
snapshots or subtree sharing, hierarchical consistency of the LRU), a
node will only ever have one AllocID as long as it is in memory.

Other choices of identifier that were considered and rejected:
- locations: old location would introduce some ambiguities (wrapping
  reuses locations), require updating on flushes, and not cover new
  nodes.  New one can't be predicted.
- generations: same issues as locations mostly
- direct ownership through references: that might work, but
  would interfere with lru ownership, probably requiring ephemerons
  somewhere

When dropping items from cache, there is still some work required
to record the location of nodes on their parents.
Parents were only referencing them by their AllocIDs, and will
switch back to using locations at this point.  Only clean nodes
can be dropped, so the location is known.

The following can keep an alloc id alive:
- it's been lent to the library user through a root handle
- it's dirty
- it's been recently used and is within the LRU list

## Single ownership

Single ownership of nodes is necessary to track when a node is used,
to enable bitmap tracking for gc purposes.
Refcounting is out because we will never update in place.
Mark and sweep is also out because it would cause a ton of IO.
Single ownership also means a logical address is referenced by its parent
exactly once (ghost trees don't matter to the cache), which means the cache
can drop the logical address and use the alloc id instead.

## Garbage collection

We keep track of blocks which we have explicitly stopped using (whenever
we rewrite them to a new address).  This allows periodically sending
discards, which is useful for flash-backed stores or for thin
provisioning.
This is complemented by a full fstrim operation which trims everything
not in use.

## Integrity

Integrity checks are preferably done when mounting.  This prevents
bitrot and makes it easier to maintain integrity.  With fast_scan
enabled, we defer checks on leaves until they are loaded, but all inner
nodes are checked at mount time.  This ensures that the tree is well
formed, and builds a reliable space map.

## Concurrency

This is single-threaded at the moment.
Add locking around node updates and some cache operations to change this, possibly.
