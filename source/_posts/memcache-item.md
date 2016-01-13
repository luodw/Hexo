title: memcache源码分析之item
date: 2016-01-10 12:43:06
tags:
- memcache
- item
categories:
- memcache

toc: true

---

上篇文章分析了memcache的内存管理模块，作为一个内存数据库，内存的管理是至关重要的，例如内存的分配，内存的回收，内存重复利用等等。有了内存之后，这篇文章主要分析下item的一些操作。item.c文件还有几个和维护LRU队列的线程函数相关，最后在统一整理。

# item定义

----

先来看下item是如何定义的，在memcached.h文件中
```
typedef struct _stritem {
    /* 受LRU locks保护 */
    struct _stritem *next;//LRU队列的下一个item
    struct _stritem *prev;//LRU队列的前一个item
    /* 剩下其他的受item lock保护 */
    struct _stritem *h_next;    /* 哈希链中的下一个item */
    rel_time_t      time;       /* 上一次访问的时间 */
    rel_time_t      exptime;    /* 过期时间 */
    int             nbytes;     /* 数据的大小 */
    unsigned short  refcount;   /* 这个item引用的次数 */
    uint8_t         nsuffix;    /* flag和val_lenth的长度 */
    uint8_t         it_flags;   /* ITEM_*标识 */
    uint8_t         slabs_clsid;/* 位于哪个slabclass中 */
    uint8_t         nkey;       /* key的长度*/
    union {
        uint64_t cas;
        char end;
    } data[];
    /* if it_flags & ITEM_CAS we have 8 bytes CAS */
    /* then null-terminated key */
    /* then " flags length\r\n" (no terminating null) */
    /* then data with terminating \r\n (no terminating null; it's binary!) */
} item;
```
其他都很好理解，关键是最后那个union data\[\]。当初在看STL源码的时候，内存分配器也有用到这中结构。这可以理解为柔性数组。因为data\[\]数组并没有显示指出数组的大小，所以这个数组是不分配内存的，但是data指针始终指向nkey属性的下一个地址。当需要nbytes字节内存时，直接在data上分配内存即可。可以看下我之前文章[柔性数组](http://luodw.cc/2015/10/22/Cplus6/ "")。最后英文注释的意思是如果设置了cas验证，则data指向的内容为CAS（8bytes)+key+"flags length\r\n"+data\r\n 。下图是这个item的示意图，图片来自网络:
![item示意图](http://7xjnip.com1.z0.glb.clouddn.com/选区_052.png "")

# items分配内存

-----

memcache上任何的键值对，都需要封装成item的形式，然后才存储到slab的管理的内存中。所以当有个set命令到达时，首先要做的是先给这个键值对分配一块chunk来存储这个键值对item。申请内存函数如下：
```
static size_t item_make_header(const uint8_t nkey, const int flags, const int nbytes,
                     char *suffix, uint8_t *nsuffix) {
    /* suffix 是do_item_alloc函数中定义的40字节数组 */
    *nsuffix = (uint8_t) snprintf(suffix, 40, " %d %d\r\n", flags, nbytes - 2);
    return sizeof(item) + nkey + *nsuffix + nbytes;
}//这个函数先计算出这个item头的长度
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
item *do_item_alloc(char *key, const size_t nkey, const int flags,
                    const rel_time_t exptime, const int nbytes,
                    const uint32_t cur_hv) {
    int i;
    uint8_t nsuffix;
    item *it = NULL;
    char suffix[40];
    unsigned int total_chunks;
    size_t ntotal = item_make_header(nkey + 1, flags, nbytes, suffix, &nsuffix);
    if (settings.use_cas) {//如果有使用cas，则还要加上8字节
        ntotal += sizeof(uint64_t);
    }

    unsigned int id = slabs_clsid(ntotal);//选择slabclass
    if (id == 0)
        return 0;
    for (i = 0; i < 5; i++) {
        /* Try to reclaim memory first */
        if (!settings.lru_maintainer_thread) {
            lru_pull_tail(id, COLD_LRU, 0, false, cur_hv);
        }
        it = slabs_alloc(ntotal, id, &total_chunks);
        if (settings.expirezero_does_not_evict)
            total_chunks -= noexp_lru_size(id);
        if (it == NULL) {
            if (settings.lru_maintainer_thread) {
                lru_pull_tail(id, HOT_LRU, total_chunks, false, cur_hv);
                lru_pull_tail(id, WARM_LRU, total_chunks, false, cur_hv);
                lru_pull_tail(id, COLD_LRU, total_chunks, true, cur_hv);
            } else {
                lru_pull_tail(id, COLD_LRU, 0, true, cur_hv);
            }
        } else {
            break;
        }
    }
    assert(it->slabs_clsid == 0);
    //assert(it != heads[id]);

    //初始化item各部分信息
    it->next = it->prev = it->h_next = 0;
    it->slabs_clsid = id;
    DEBUG_REFCNT(it, '*');
    it->it_flags = settings.use_cas ? ITEM_CAS : 0;
    it->nkey = nkey;
    it->nbytes = nbytes;
    memcpy(ITEM_key(it), key, nkey);
    it->exptime = exptime;
    memcpy(ITEM_suffix(it), suffix, (size_t)nsuffix);
    it->nsuffix = nsuffix;
    return it;
}
```
这个函数主要是为item分配内存使用的，slab可能内存已经使用完了，这时需要从LRU队列中删除item，以至于腾出内存，这之后研究LRU平衡线程时再分析，这里假设分配到内存了。接下来就是初始化分配到的item。这里并没有把value值复制到item中，而是调用这个do_item_alloc函数之后再赋值。

# item内存回收

---

item内存回收很简单。当某个Item的引用计数变为0时，这时线程会调用item_free函数回收item这块内存，但不是将内存还给系统，而是将内存还给slab。即将这个item插入链表slots中。
```
void item_free(item *it) {
    size_t ntotal = ITEM_ntotal(it);
    unsigned int clsid;
    assert((it->it_flags & ITEM_LINKED) == 0);
    assert(it != heads[it->slabs_clsid]);
    assert(it != tails[it->slabs_clsid]);
    assert(it->refcount == 0);

    /* so slab size changer can tell later if item is already free or not */
    clsid = ITEM_clsid(it);
    DEBUG_REFCNT(it, 'F');
    slabs_free(it, ntotal, clsid);//slab回收内存
}
```
# item插入和删除LRU队列

---

接来下函数是将item插入和删除LRU队列
```
static void do_item_link_q(item *it) { /* item is the new head */
    item **head, **tail;
    assert((it->it_flags & ITEM_SLABBED) == 0);

    head = &heads[it->slabs_clsid];
    tail = &tails[it->slabs_clsid];
    assert(it != *head);
    assert((*head && *tail) || (*head == 0 && *tail == 0));
    it->prev = 0;
    it->next = *head;
    if (it->next) it->next->prev = it;
    *head = it;
    if (*tail == 0) *tail = it;
    sizes[it->slabs_clsid]++;//sizes保存这个id的slabclass的Item数量
    return;
}

static void item_link_q(item *it) {//插入LRU队列的有锁版本
    pthread_mutex_lock(&lru_locks[it->slabs_clsid]);
    do_item_link_q(it);
    pthread_mutex_unlock(&lru_locks[it->slabs_clsid]);
}

static void do_item_unlink_q(item *it) {
    item **head, **tail;
    head = &heads[it->slabs_clsid];
    tail = &tails[it->slabs_clsid];

    if (*head == it) {
        assert(it->prev == 0);
        *head = it->next;
    }
    if (*tail == it) {
        assert(it->next == 0);
        *tail = it->prev;
    }
    assert(it->next != it);
    assert(it->prev != it);

    if (it->next) it->next->prev = it->prev;
    if (it->prev) it->prev->next = it->next;
    sizes[it->slabs_clsid]--;
    return;
}

static void item_unlink_q(item *it) {//LRU删除item有锁版本
    pthread_mutex_lock(&lru_locks[it->slabs_clsid]);
    do_item_unlink_q(it);
    pthread_mutex_unlock(&lru_locks[it->slabs_clsid]);
}
```
这就是链表插入和删除操作，没什么好解释的。

# item插入和删除LRU和哈希表

----

item插入和删除LRU和哈希表其实就是在一个函数中先调用哈希表的插入函数，然后在调用LRU插入函数。
```
int do_item_link(item *it, const uint32_t hv) {
    MEMCACHED_ITEM_LINK(ITEM_key(it), it->nkey, it->nbytes);
    assert((it->it_flags & (ITEM_LINKED|ITEM_SLABBED)) == 0);
    it->it_flags |= ITEM_LINKED;//表示这个item在链表中
    it->time = current_time;

    STATS_LOCK();//更新状态信息
    stats.curr_bytes += ITEM_ntotal(it);
    stats.curr_items += 1;
    stats.total_items += 1;
    STATS_UNLOCK();

    /* Allocate a new CAS ID on link. */
    ITEM_set_cas(it, (settings.use_cas) ? get_cas_id() : 0);
    assoc_insert(it, hv);//哈希表插入
    item_link_q(it);//LRU链表插入
    refcount_incr(&it->refcount);//引用数加1

    return 1;
}

void do_item_unlink(item *it, const uint32_t hv) {
    MEMCACHED_ITEM_UNLINK(ITEM_key(it), it->nkey, it->nbytes);
    if ((it->it_flags & ITEM_LINKED) != 0) {
        it->it_flags &= ~ITEM_LINKED;//关闭标识
        STATS_LOCK();
        stats.curr_bytes -= ITEM_ntotal(it);
        stats.curr_items -= 1;
        STATS_UNLOCK();
        assoc_delete(ITEM_key(it), it->nkey, hv);//哈希表删除
        item_unlink_q(it);//LRU链表删除
        do_item_remove(it);//当it引用数为0时，回收item。
    }
}

void do_item_remove(item *it) {
    MEMCACHED_ITEM_REMOVE(ITEM_key(it), it->nkey, it->nbytes);
    assert((it->it_flags & ITEM_SLABBED) == 0);
    assert(it->refcount > 0);

    if (refcount_decr(&it->refcount) == 0) {
        item_free(it);//先将引用数减1，然后再判断是否为0.
    }
}
```

# item更新替换

----

LRU为最近最少使用策略，所以每次访问LRU列表中的某个item时，需要将这个item移到LRU最新的位置。反应到代码操作上就是先删除这个item,然后再重新插入LRU链表即可
```
void do_item_update(item *it) {
    MEMCACHED_ITEM_UPDATE(ITEM_key(it), it->nkey, it->nbytes);
    if (it->time < current_time - ITEM_UPDATE_INTERVAL) {
        assert((it->it_flags & ITEM_SLABBED) == 0);

        if ((it->it_flags & ITEM_LINKED) != 0) {
            it->time = current_time;
            if (!settings.lru_maintainer_thread) {
                item_unlink_q(it);
                item_link_q(it);
            }
        }
    }
}
```
item的替换意思就是如果有更新键值对，则需要将原先的键值对删除，然后再将最新的键值对插入LRU和哈希表。
```
int do_item_replace(item *it, item *new_it, const uint32_t hv) {
    MEMCACHED_ITEM_REPLACE(ITEM_key(it), it->nkey, it->nbytes,
                           ITEM_key(new_it), new_it->nkey, new_it->nbytes);
    assert((it->it_flags & ITEM_SLABBED) == 0);

    do_item_unlink(it, hv);
    return do_item_link(new_it, hv);
}
```

# item查询

----

memcache采取lazy expiration逻辑，即使用flush命令时，并不是真正的删除Item节点，而是在查询时，再来判断这个item是否有效，如果无效，则要回收item。
```
item *do_item_get(const char *key, const size_t nkey, const uint32_t hv) {
    item *it = assoc_find(key, nkey, hv);
    if (it != NULL) {
        refcount_incr(&it->refcount);//引用数+1
 }
    int was_found = 0;

    if (settings.verbose > 2) {
        int ii;
        if (it == NULL) {
            fprintf(stderr, "> NOT FOUND ");
        } else {
            fprintf(stderr, "> FOUND KEY ");
            was_found++;
        }
        for (ii = 0; ii < nkey; ++ii) {
            fprintf(stderr, "%c", key[ii]);
        }
    }

    if (it != NULL) {
        if (is_flushed(it)) {//判断item是否过期，包括flush时间点过期和cas过期
            do_item_unlink(it, hv);//过期则从LRU和哈希表中删除
            do_item_remove(it);//引用数为1时，回收item
            it = NULL;
            if (was_found) {
                fprintf(stderr, " -nuked by flush");
            }
        } else if (it->exptime != 0 && it->exptime <= current_time) {//判断item节点是否生命到期
            do_item_unlink(it, hv);
            do_item_remove(it);
            it = NULL;
            if (was_found) {
                fprintf(stderr, " -nuked by expire");
            }
        } else {
            it->it_flags |= ITEM_FETCHED|ITEM_ACTIVE;//这里表示这个节点没有到期，可以正常使用
            DEBUG_REFCNT(it, '+');
        }
    }

    if (settings.verbose > 2)
        fprintf(stderr, "\n");

    return it;
}
//下面是更新item过期时间函数
item *do_item_touch(const char *key, size_t nkey, uint32_t exptime,
                    const uint32_t hv) {
    item *it = do_item_get(key, nkey, hv);
    if (it != NULL) {
        it->exptime = exptime;
    }
    return it;
}
```
 item的其他函数和平衡LRU和平衡哈希表相关，之后统一分析。














