# Semantics

Wodan provides a persistent store containing ordered mappings.

## Persistence

Updates affect the in-memory view of the store.
They are not persisted until a flush is explicitly requested.

## Generations

When flushing, a generation number is returned.
Generations grow at every flush.

## Keys

Keys are fixed-size byte sequences.

Keys can be accessed in lexicographical order, with amenities such as
range searches.

## Mappings

Key-value mappings are mutable, and later updates shadow previous
writes.

## Values

Values are byte sequences of bounded size.

### Tombstones

Values are generally treated as opaque.

An exception is if tombstone support is enabled (at filesystem creation
time); mapping to the empty value is then treated as absence of the
mapping.

Since tombstone semantics persist across mounts, when tombstones reach a
leaf, they can be removed entirely.

This allows tombstones to be used to provide an operation that deletes
mappings.  The caller will have to ensure that empty values don't become
ambiguous.  Some encodings never produce empty values, but when
arbitrary data needs to be handled, a one-byte prefix is a good
solution.

In the future, upsert semantics could be added by using the first byte
as a tag byte.  Operations like appending would then be possible.
