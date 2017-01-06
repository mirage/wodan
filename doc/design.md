
## Caching

Caching is done at the block level.

## Cache priority

There's an LRU list that combines clean and dirty items.
Flushing dirty items doesn't bump them or discard them from the cache.
They become clean, their priority order stays the same.

### Ephemerons and cache liveness

Make it so that a LRU entry keeps its parent node alive.
Use an ephemeron-keyed lru_entry -> lru_entry map.
Or a node -> node map.  Nodes need to hash to their old generation
for that to work.

For the dirty set, use a tree.
Have a mark_parents_dirty function that makes sure
everybody in the parent chain gets a pointer to their now dirty child.

## Allocation and adressing cache items

When a node has been modified in-memory, we don't have an easy way to identify it.
We don't know where it will be located on disk.  We can't use the old address
because of wrap concerns.  We can't allocate a new generation or logical address, because
with churn it might become obsolete before hitting the disk, and we would end
up with gaps.
We might try to use the old generation but it will change 
once the node is flushed.  
If we reuse generation numbers, they must now be unique; previously siblings (not roots)
could reuse a generation number.  Adds another consistency check.
Oh, another problem with this: new nodes that have never hit the disk don't
have a generation number.  So don't use generation numbers.

We introduce allocation ids to solve this problem.
This doesn't solve the flush issue entirely.  We might need to track
owners (which is feasible with single ownership) and update their id at
flush time.  Doable but ugly.

We introduce cache ids to solve this problem.
These solve the issue entirely, at the cost of a slightly more complicated
load operation.  When loading by logical id, we return the cache id, and
plop it in place of the logical id in the parent.
The following can keep a cache id alive:
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
can drop the logical address and use the cache id instead.

## Garbage collection

Do we keep track of which blocks are known to be discarded?
Or do we make at least the first trim a full trim?

## Consistency

Some checks done when mounting.
When fast mounting is available, most checks will only be done for
blocks that are more recent than the newest logged bitmap.

Children mustn't be shared (single-ownership)

## Concurrency

This is single-threaded at the moment.
Add locking around node updates and some cache operations to change this, possibly.

## Dependencies

* Serialisation: Cstruct for now.  Need the portability.
  * Proto-bufs?
  * msgpack?
* High-level fs: Irmin.
* CRC32C
  * bundled, done
  * Switch to an optimised C version?  Linking will be an issue.
  * Librarify?  Add to mirage-platform?
* Lwt. Not going to abstract over this one.

## Testing

Alcotest, which is from Mirage?
Build cstructs from hex.  Or just do the reverse, build the normal way,
check the hexdump matches.

