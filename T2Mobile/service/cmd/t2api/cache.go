package main

// A bounded, concurrency-safe cache of encoded probe columns. Least-recently-used entries
// are dropped when the byte budget is exceeded. Concurrent requests for a probe that is not
// cached yet share ONE database query (the others wait for it), so a burst of identical
// requests costs a single lookup. "No such probe" is cached too (as an empty entry), so
// asking for nonsense repeatedly cannot be used to hammer the database.

import (
	"container/list"
	"sync"
	"sync/atomic"
)

type cacheEntry struct {
	key   string
	value []byte // nil = known to be missing
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

	p.value, p.err = load()

	c.mu.Lock()
	delete(c.pending, key)
	if p.err == nil {
		c.items[key] = c.order.PushFront(&cacheEntry{key: key, value: p.value})
		c.used += int64(len(p.value)) + int64(len(key)) + 64
		for c.used > c.budget && c.order.Len() > 1 {
			last := c.order.Back()
			e := last.Value.(*cacheEntry)
			c.order.Remove(last)
			delete(c.items, e.key)
			c.used -= int64(len(e.value)) + int64(len(e.key)) + 64
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
