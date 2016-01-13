title: memcache源码分析之slab内存分配
date: 2016-01-09 16:17:29
tags:
- memcache
- slab 
categories:
- memcache
toc: true

---

昨天分析了memcache的整体软件架构，主要是线程模型和内存模型，今天主要分析下memcache的内存分配组件slab。slab是memcache的内存池结构，它将内存分为一系列固定大小内存的内存块chunk，线程每次申请内存时，选择和所需的内存大小最接近(大于等于)的内存即可。把slab的内存模型再次献上:
![slab内存模型](http://7xjnip.com1.z0.glb.clouddn.com/1345021404_1576.png "");

memcache事先会分配一大块内存，通过-m来设置，然后slab每次申请内存都从大块内存中分配，这样可以减少malloc的调用。slab支持预先分配内存，即一开始就给每个slabclass分配一块内存页，需要开始时输入-k选项，默认情况下是不预先分配内存的。下面还是分析源码来解释slab。
# slab定义

----

先来看下关于slab的一些定义：
```
typedef struct {
    unsigned int size;      /*这个slabclass的chunk大小*/
    unsigned int perslab;   /* 每个内存页有多少个chunk */

    void *slots;           /* 回收来的item内存块 */
    unsigned int sl_curr;   /* slots链表中有多少个item内存块*/

    unsigned int slabs;     /* 这个slabclass分配了多少个内存页*/

    void **slab_list;       /* 每个内存页指针数组*/
    unsigned int list_size; /* 这个内存页指针数组的大小*/

    unsigned int killing;  /* index+1 of dying slab, or zero if none*/
    size_t requested; /* 这个slabclass已经被申请走的内存*/
} slabclass_t;

static slabclass_t slabclass[MAX_NUMBER_OF_SLAB_CLASSES];//slabclass数组，默认大小为64
static size_t mem_limit = 0;//预先分配内存大小，即内存池的大小
static size_t mem_malloced = 0;//到目前位置已经被分配出去的内存大小，可以统计memcache数据
占有的内存大小

static bool mem_limit_reached = false;//是否已经达到内存池大小，如果是，则要执行LRU策略
static int power_largest;//真实slaclass数组的最大值。

static void *mem_base = NULL;//内存池的首地址
static void *mem_current = NULL;//指向可用内存的第一个字节
static size_t mem_avail = 0;//可用的内存块大小。
```
这些都是slab.c文件中定义的数据结构和变量。关键要理解slabclass属性表示什么，属性中，slots和slab_list最为重要。

# slab初始化

----

memcache一开始会初始化slab，然后在item.c文件中，当需要申请内存时，就调用slabs_alloc分配内存，当需要回收内存时，就调用slabs_free函数。先来看下slabs_init函数：
```
void slabs_init(const size_t limit, const double factor, const bool prealloc) {
    int i = POWER_SMALLEST - 1;//POWER_SMALLEST为slabclass数组索引最小值，为1.
    unsigned int size = sizeof(item) + settings.chunk_size;//chunk的最小值，默认为96

    mem_limit = limit;//内存池的大小，默认是64M

    if (prealloc) {
        /* 如果预先分配内存 */
        mem_base = malloc(mem_limit);//分配内存池
        if (mem_base != NULL) {
            mem_current = mem_base;
            mem_avail = mem_limit;
        } else {
            fprintf(stderr, "Warning: Failed to allocate requested memory in"
                    " one large chunk.\nWill allocate in smaller chunks\n");
        }
    }

    memset(slabclass, 0, sizeof(slabclass));//初始化slabclass数组

    while (++i < MAX_NUMBER_OF_SLAB_CLASSES-1 && size <= settings.item_size_max / factor) {
        /* 保证每个chunk是8字节对齐 */
        if (size % CHUNK_ALIGN_BYTES)
            size += CHUNK_ALIGN_BYTES - (size % CHUNK_ALIGN_BYTES);

        slabclass[i].size = size;//第i个slabclass负责的chunk大小
        slabclass[i].perslab = settings.item_size_max / slabclass[i].size;//第i个slabclass,每
每个内存页chunk的个数
        size *= factor;//下个slabclass的chunk大小
        if (settings.verbose > 1) {
            fprintf(stderr, "slab class %3d: chunk size %9u perslab %7u\n",
                    i, slabclass[i].size, slabclass[i].perslab);
        }
    }

    power_largest = i;//最后一个slabclass，chunk为1M，且只有一个chunk。
    slabclass[power_largest].size = settings.item_size_max;
    slabclass[power_largest].perslab = 1;
    if (settings.verbose > 1) {
        fprintf(stderr, "slab class %3d: chunk size %9u perslab %7u\n",
                i, slabclass[i].size, slabclass[i].perslab);
    }

    /* for the test suite:  faking of how much we've already malloc'd */
    {
        char *t_initial_malloc = getenv("T_MEMD_INITIAL_MALLOC");
        if (t_initial_malloc) {
            mem_malloced = (size_t)atol(t_initial_malloc);
        }
    }//调试用，可以不理

    if (prealloc) {
        slabs_preallocate(power_largest);//预先为每一个slabclass分配一个内存页
    }
}
```
slabs_init函数做的工作主要是初始化slabclass，然后如果有设置预先分配内存，则先分配一大块内存作为内存池，然后在为每一个slabclass分配一个内存页，接下来看下slabs_preallocate函数，是如何分配内存页的。

```
static void slabs_preallocate (const unsigned int maxslabs) {
    int i;
    unsigned int prealloc = 0;

    for (i = POWER_SMALLEST; i < MAX_NUMBER_OF_SLAB_CLASSES; i++) {
        if (++prealloc > maxslabs)
            return;//如果大于最大slab索引，则返回
        if (do_slabs_newslab(i) == 0) {//为第i个slabclass分配一个内存页
            fprintf(stderr, "Error while preallocating slab memory!\n"
                "If using -L or other prealloc options, max memory must be "
                "at least %d megabytes.\n", power_largest);
            exit(1);
        }
    }
}
```
这个函数只是简单的给个for循环，从slabclass最小索引1到最大索引maxslab，分别调用do_slabs_newslab来分配一块内存页。

```
static int do_slabs_newslab(const unsigned int id) {
    slabclass_t *p = &slabclass[id];
    int len = settings.slab_reassign ? settings.item_size_max
        : p->size * p->perslab;//这句主要是判断新分配的内存页是1M了，还是p->size*p->perslab，
//因为后者不一定等于1M。
    char *ptr;

    if ((mem_limit && mem_malloced + len > mem_limit && p->slabs > 0)) {
        mem_limit_reached = true;
        MEMCACHED_SLABS_SLABCLASS_ALLOCATE_FAILED(id);
        return 0;
    }//如果有设置内存使用最大值而且已近分配的内存加上即将分配的内存大于mem_limit而且
这个slabclass内存页不为空，则说明内存使用已经达到最大值。

    if ((grow_slab_list(id) == 0) ||
        ((ptr = memory_allocate((size_t)len)) == 0)) {//先将内存页数组的id加1，然后分配内存页

        MEMCACHED_SLABS_SLABCLASS_ALLOCATE_FAILED(id);
        return 0;
    }

    memset(ptr, 0, (size_t)len);
    split_slab_page_into_freelist(ptr, id);//将内存页分割成一定数量的chunk

    p->slab_list[p->slabs++] = ptr;//slab_list数组索引加1，将内存页首地址赋给这个数组元素
    mem_malloced += len;//已分配内存加上len
    MEMCACHED_SLABS_SLABCLASS_ALLOCATE(id);

    return 1;
}
```
这个函数主要是用于分配一块内存页，接着将这块内存页分割成chunk，并把每个chunk的首地址指针串接在p->slots上，表示可用的chunk。最后将内存页赋给slab_list数组元素。接下来看下其中的几个小函数。
```
static int grow_slab_list (const unsigned int id) {
    slabclass_t *p = &slabclass[id];
    if (p->slabs == p->list_size) {
    /*如果slab_list元素已满，(1)如果是初始化时，直接数组大小设为16，如果p-list_size!=0,
    则数组大小翻倍*/
        size_t new_size =  (p->list_size != 0) ? p->list_size * 2 : 16;
        //给slab_list重新分配内存
        void *new_list = realloc(p->slab_list, new_size * sizeof(void *));
        if (new_list == 0) return 0;
        p->list_size = new_size;
        p->slab_list = new_list;
    }
    return 1;
}
/*++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
tatic void split_slab_page_into_freelist(char *ptr, const unsigned int id) {
    slabclass_t *p = &slabclass[id];
    int x;
    for (x = 0; x < p->perslab; x++) {
	    do_slabs_free(ptr, 0, id);//调用do_slabs_free将新分配的内存页回收，即挂到p->slots
	    ptr += p->size;
    }
}
/*+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
static void do_slabs_free(void *ptr, const size_t size, unsigned int id) {
    slabclass_t *p;
    item *it;

    assert(id >= POWER_SMALLEST && id <= power_largest);
    if (id < POWER_SMALLEST || id > power_largest)
        return;

    MEMCACHED_SLABS_FREE(size, id, ptr);
    p = &slabclass[id];

    it = (item *)ptr;将Ptr指针指向的内存强制转化为item指针
    it->it_flags |= ITEM_SLABBED;
    it->slabs_clsid = 0;
    it->prev = 0;
    it->next = p->slots;//添加到p->slots
    if (it->next) it->next->prev = it;
    p->slots = it;

    p->sl_curr++;//可用的item加1
    p->requested -= size;//已经分配的内存减size
    return;
}
```
至此，每个slabclass预先分配一个内存页，然后每个内存页都切割成相应的大小，并且指针挂到p->slots中，表示可用的item。需要说下几点:
1. 一开始时，slab默认分配的slab_list数组大小为16,之后数组存满时，再把数组大小翻倍；
2. 将刚分配的内存页指针挂到p->slots上，其实就相当于回收刚分配的内存，变为可用，所以调用do_slabs_free。

# slab申请内存

-----

当slab初始化好内存之后，当线程执行插入操作时，需要将键值对封装成item结构，而item结构就需要到slab内存池申请内存，这时就调用slabs_alloc函数
```
void *slabs_alloc(size_t size, unsigned int id, unsigned int *total_chunks) {
    void *ret;
    //因为memcache是多线程模型，而slab是一种共享资源，所以必须加锁
    pthread_mutex_lock(&slabs_lock);
    ret = do_slabs_alloc(size, id, total_chunks);
    pthread_mutex_unlock(&slabs_lock);
    return ret;
}
/*+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
static void *do_slabs_alloc(const size_t size, unsigned int id, unsigned int *total_chunks) {
    slabclass_t *p;
    void *ret = NULL;
    item *it = NULL;

    if (id < POWER_SMALLEST || id > power_largest) {
        MEMCACHED_SLABS_ALLOCATE_FAILED(size, 0);
        return NULL;
    }
    p = &slabclass[id];
    assert(p->sl_curr == 0 || ((item *)p->slots)->slabs_clsid == 0);

    *total_chunks = p->slabs * p->perslab;//这个slabclass所有chunk个数
    /* fail unless we have space at the end of a recently allocated page,
       we have something on our freelist, or we could allocate a new page */
    if (! (p->sl_curr != 0 || do_slabs_newslab(id) != 0)) {
        /* 没有更多的内存了*/
        ret = NULL;
    } else if (p->sl_curr != 0) {
        /* p->slots还有可用的item内存块 */
        it = (item *)p->slots;
        p->slots = it->next;
        if (it->next) it->next->prev = 0;
        /* Kill flag and initialize refcount here for lock safety in slab
         * mover's freeness detection. */
        it->it_flags &= ~ITEM_SLABBED;//关闭这个标识，表示被分配出去了
        it->refcount = 1;
        p->sl_curr--;
        ret = (void *)it;
    }

    if (ret) {
        p->requested += size;
        MEMCACHED_SLABS_ALLOCATE(size, id, p->size, ret);
    } else {
        MEMCACHED_SLABS_ALLOCATE_FAILED(size, id);
    }

    return ret;
}
```
这两个函数相对较好理解，多线程执行时，先锁住全局slab，然后将p->slots第一个指针指向的内存分配出去。接下来看下内存释放操作

# slab回收内存

----

slab并没有真正的释放item的内存，而是这块内存的指针插入p->slots的链表表头，这样下次需要时，即可重复利用这块内存。
```
void slabs_free(void *ptr, size_t size, unsigned int id) {
    pthread_mutex_lock(&slabs_lock);
    do_slabs_free(ptr, size, id);
    pthread_mutex_unlock(&slabs_lock);
}
/*+++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
```
这调用之前的那个do_slab_free函数，回收ptr指向的大小为size的内存块。

# 查询slab状态信息

----

slab还有一个函数用于查询slab的状态信息，比如分配了多少个内存页，内存申请了多少等等。代码如下：
```
void slabs_stats(ADD_STAT add_stats, void *c) {
    pthread_mutex_lock(&slabs_lock);
    do_slabs_stats(add_stats, c);
    pthread_mutex_unlock(&slabs_lock);
}
/*++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
static void do_slabs_stats(ADD_STAT add_stats, void *c) {
    int i, total;
    /* Get the per-thread stats which contain some interesting aggregates */
    struct thread_stats thread_stats;
    threadlocal_stats_aggregate(&thread_stats);

    total = 0;
    for(i = POWER_SMALLEST; i <= power_largest; i++) {
        slabclass_t *p = &slabclass[i];
        if (p->slabs != 0) {
            uint32_t perslab, slabs;
            slabs = p->slabs;
            perslab = p->perslab;

            char key_str[STAT_KEY_LEN];
            char val_str[STAT_VAL_LEN];
            int klen = 0, vlen = 0;

            APPEND_NUM_STAT(i, "chunk_size", "%u", p->size);
            APPEND_NUM_STAT(i, "chunks_per_page", "%u", perslab);
            APPEND_NUM_STAT(i, "total_pages", "%u", slabs);
            APPEND_NUM_STAT(i, "total_chunks", "%u", slabs * perslab);
            APPEND_NUM_STAT(i, "used_chunks", "%u",
                            slabs*perslab - p->sl_curr);
            APPEND_NUM_STAT(i, "free_chunks", "%u", p->sl_curr);
            /* Stat is dead, but displaying zero instead of removing it. */
            APPEND_NUM_STAT(i, "free_chunks_end", "%u", 0);
            APPEND_NUM_STAT(i, "mem_requested", "%llu",
                            (unsigned long long)p->requested);
            APPEND_NUM_STAT(i, "get_hits", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].get_hits);
            APPEND_NUM_STAT(i, "cmd_set", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].set_cmds);
            APPEND_NUM_STAT(i, "delete_hits", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].delete_hits);
            APPEND_NUM_STAT(i, "incr_hits", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].incr_hits);
            APPEND_NUM_STAT(i, "decr_hits", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].decr_hits);
            APPEND_NUM_STAT(i, "cas_hits", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].cas_hits);
            APPEND_NUM_STAT(i, "cas_badval", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].cas_badval);
            APPEND_NUM_STAT(i, "touch_hits", "%llu",
                    (unsigned long long)thread_stats.slab_stats[i].touch_hits);
            total++;
        }
    }
```
这两个函数主要做的事就是将这些信息存放到一个这个连接的buf输出字符数组中，然后将在一个epoll轮询时，把数据输出给客户端。

最后几个函数是和平衡slab的线程相关的，之后统一在分析这些辅助线程。
```
int start_slab_maintenance_thread(void);
void stop_slab_maintenance_thread(void);
void slabs_rebalancer_pause(void);
void slabs_rebalancer_resume(void);
```













