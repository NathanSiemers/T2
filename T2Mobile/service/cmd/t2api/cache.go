package main

// A bounded, concurrency-safe cache of encoded probe columns. Least-recently-used entries
// are dropped when the byte budget is exceeded. Concurrent requests for a probe that is not
// cached yet share ONE database query (the others wait for it), so a burst of identical
// requests costs a single lookup. Only real columns are kept: names that are not variables
// of the dataset never get here (Dataset.column checks the name list first), and a name
// without data is not stored, so nonsense requests cannot fill memory. A panic while
// loading is turned into an error for everyone waiting, never a name stuck "pending".

import (
	"container/list"
	"fmt"
	"sync"
	"sync/atomic"
)

// what one entry costs beyond its bytes: list element, entry, map bucket, key header
const entryOverhead = 256

type cacheEntry struct {
	key   string
	value []byte
}

type inflight struct {
	done  chan struct{}
	value []byte
	err   error
}

type columnCache struct {
	mu       sync.Mutex
	budget   int64
	used     int64
	order    *list.List // front = most recently used
	items    map[string]*list.Element
	pending  map[string]*inflight
	hits     atomic.Int64
	misses   atomic.Int64
	evicted  atomic.Int64
}

func newColumnCache(budget int64) *columnCache {
	return &columnCache{budget: budget, order: list.New(), items: map[string]*list.Element{}, pending: map[string]*inflight{}}
}

func (c *columnCache) get(key string, load func() ([]byte, error)) ([]byte, error) {
	c.mu.Lock()
	if el, ok := c.items[key]; ok {
		c.order.MoveToFront(el)
		v := el.Value.(*cacheEntry).value
		c.mu.Unlock()
		c.hits.Add(1)
		return v, nil
	}
	if p, ok := c.pending[key]; ok { // someone is already fetching it
		c.mu.Unlock()
		<-p.done
		c.hits.Add(1)
		return p.value, p.err
	}
	p := &inflight{done: make(chan struct{})}
	c.pending[key] = p
	c.mu.Unlock()
	c.misses.Add(1)

	func() {
		defer func() {
			if r := recover(); r != nil {
				p.value, p.err = nil, fmt.Errorf("panic while loading %q: %v", key, r)
			}
		}()
		p.value, p.err = load()
	}()

	c.mu.Lock()
	delete(c.pending, key)
	if p.err == nil && p.value != nil {
		c.items[key] = c.order.PushFront(&cacheEntry{key: key, value: p.value})
		c.used += int64(len(p.value)) + int64(len(key)) + entryOverhead
		for c.used > c.budget && c.order.Len() > 1 {
			last := c.order.Back()
			e := last.Value.(*cacheEntry)
			c.order.Remove(last)
			delete(c.items, e.key)
			c.used -= int64(len(e.value)) + int64(len(e.key)) + entryOverhead
			c.evicted.Add(1)
		}
	}
	c.mu.Unlock()
	close(p.done)
	return p.value, p.err
}

func (c *columnCache) stats() map[string]int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return map[string]int64{"entries": int64(c.order.Len()), "bytes": c.used, "budget_bytes": c.budget,
		"hits": c.hits.Load(), "misses": c.misses.Load(), "evicted": c.evicted.Load()}
}
