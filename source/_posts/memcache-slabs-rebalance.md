title: memcache源码分析之slabs平衡线程
date: 2016-01-18 18:47:26
tags:
- memcache
categories:
- memcache
toc: true

---

上篇文章分析了memcache哈希表维护线程，其实就是哈希表的扩容线程。这篇文章分析memcache第二个辅助线程slabs平衡线程。先说下这个线程的由来。

在一开始，由于业务原因向memcached存储大量长度为1KB的数据，也就是说memcached服务器进程里面有很多大小为1KB的item。现在由于业务调整需要存储大量10KB的数据，并且很少使用1KB的那些数据了。由于数据越来越多，内存开始吃紧。大小为10KB的那些item频繁访问，并且由于内存不够需要使用LRU淘汰一些10KB的item。

对于上面的情景，会不会觉得大量1KB的item实在太浪费了。由于很少访问这些item，所以即使它们超时过期了，还是会占据着哈希表和LRU队列。LRU队列还好，不同大小的item使用不同的LRU队列。但对于哈希表来说大量的僵尸item会增加哈希冲突的可能性，并且在迁移哈希表的时候也浪费时间。有没有办法干掉这些item？使用LRU爬虫+lru_crawler命令是可以强制干掉这些僵尸item。但干掉这些僵尸item后，它们占据的内存是归还到1KB的那些slab分配器中。1KB的slab分配器不会为10KB的item分配内存。所以还是功亏一篑。

为了解决上述所说的内存浪费，memcache设计了两个辅助线程slab_mantenance_thread和slab_rebalance_thread。这两个线程是由同一个函数开启的，即 
```
if (settings.slab_reassign &&
        start_slab_maintenance_thread() == -1) {
        exit(EXIT_FAILURE);
    }
```
也就说如果要开启这两个线程必须在开启memcache服务器时，加上选项memcached -o slab_reassign. 开启这两个线程之后，需要先说明下这两个线程的作用:
1. maintenance线程做的就是处于一个循环中，检查是否需要进行一次内存页迁移，如果条件满足，则slabs_reassign函数给rebalance线程发送信号，唤起rebalance线程处理内存页迁移操作。但是，如果要使maintenance线程起作用关键，还要设置settings.slab\_automove=1.即在memcached启动时，加上memcached -o slab\_reassign,slab\_automove.这样开启时，automove默认值为1。
2. rebalance线程主要是处理内存页迁移，一开始该线程wait在一个条件变量中，等待slabs_reassign函数给该线程发送信号，然后才真正执行内存页的迁移。

在客户端命令中，也可以设置automove的值，即slabs automove 1.命令行中也可以手动进行内存页迁移，即slabs reassign src dst。

综上所述，
1. 如果要开启这两个线程，只能在memcache开启时添加选项memcached -o slab\_reassign。
2. 如果要设置automove的值，则可以在memcached开启时设置memcached -o slab_automove;也可以在命令行中设置slabs automove 1.
3. 也可以在命令行中手动指定两个slab进行内存页操作。slabs reassign src dst，前提是rebalance线程已开启。本质上也是调用slabs_reassign函数。

automove可以设置为0,1,2。但是在1.4.24版本中，取消了automove=2的使用，所以只要记着automove=0，表示关闭maintenance线程，automove=1表示开启maintenance线程。

接下来，先介绍maintenance线程，因为rebalance线程一开始处于睡眠状态中。

# maintenance线程

---

maintenance线程开启之后，函数处于一个while循环中，不断进行检测哪个slabclass_t需要内存页slabclass_t[dst]，哪个slabclass_t[src]有多余的内存页，如果选出这两个src,dst，则调用slabs_reassign进行内存页迁移：
```
static void *slab_maintenance_thread(void *arg) {
    int src, dest;

    while (do_run_slab_thread) {//默认为1
        if (settings.slab_automove == 1) {
            if (slab_automove_decision(&src, &dest) == 1) {
                /* Blind to the return codes. It will retry on its own */
                slabs_reassign(src, dest);
            }
            sleep(1);
        } else {
            /* Don't wake as often if we're not enabled.
             * This is lazier than setting up a condition right now. */
            sleep(5);
        }
    }
    return NULL;
}
```
由函数可以知道，如果没有设置automove，则settings.slab_automove=0，则这个函数不断调用sleep(5)，即一直处于睡眠状态。当设置了automove=1之后，则进行src,dst决策。而且src,dst必须同时不为0，才能返回1，否则进行下一次判断。来看下slab_auto_decision函数：
```
void item_stats_evictions(uint64_t *evicted) {
    int n;
    for (n = 0; n < MAX_NUMBER_OF_SLAB_CLASSES; n++) {
        int i;
        int x;
        for (x = 0; x < 4; x++) {
            i = n | lru_type_map[x];
            pthread_mutex_lock(&lru_locks[i]);
            //这个itemstats数组为itemstats_t类型，属性evicted为lru中因为内存
            //不足，强制从lru尾部提出item的次数，这个次数在一定程度上反映这个
            //slabclass_t是否内存不足。
            evicted[n] += itemstats[i].evicted;
            pthread_mutex_unlock(&lru_locks[i]);
        }
    }
}
//这个函数用于取出每一个slabclass_t的lru中item驱逐的次数。
static int slab_automove_decision(int *src, int *dst) {
    //以下4个变量为static,因为while循环要不断进入这个函数分析，这个四个变量需要
    //不断更新
    static uint64_t evicted_old[MAX_NUMBER_OF_SLAB_CLASSES];//之前统计被驱逐的次数
    static unsigned int slab_zeroes[MAX_NUMBER_OF_SLAB_CLASSES];//没有被驱逐次数
    static unsigned int slab_winner = 0;//急需内存页的候选slab
    static unsigned int slab_wins   = 0;//统计slab_winner被候选的次数
    //本次所有slabclass_t被驱逐的次数
    uint64_t evicted_new[MAX_NUMBER_OF_SLAB_CLASSES];
    uint64_t evicted_diff = 0;//这次和上次驱逐次数的差值
    uint64_t evicted_max  = 0;//本次驱逐次数的最大值
    unsigned int highest_slab = 0;//本次被选出需要内存页的slab
    unsigned int total_pages[MAX_NUMBER_OF_SLAB_CLASSES];//每个slab内存页总数
    int i;
    int source = 0;
    int dest = 0;
    static rel_time_t next_run;

    /* Run less frequently than the slabmove tester. */
    if (current_time >= next_run) {
        next_run = current_time + 10;
    } else {
        return 0;
    }//这个if语句主要是控制这函数调用的频率，因为在较短时间内，驱逐次数变化不大

    item_stats_evictions(evicted_new);//获取最新的驱逐次数
    pthread_mutex_lock(&slabs_lock);
    for (i = POWER_SMALLEST; i < power_largest; i++) {
        total_pages[i] = slabclass[i].slabs;//获取每个slabclass_t总的内存页
    }
    pthread_mutex_unlock(&slabs_lock);

    /* Find a candidate source; something with zero evicts 3+ times */
    for (i = POWER_SMALLEST; i < power_largest; i++) {
        evicted_diff = evicted_new[i] - evicted_old[i];//本次和上次驱逐次数差
        if (evicted_diff == 0 && total_pages[i] > 2) {
            slab_zeroes[i]++;//如果diff=0,且内存页大于2,则没有被驱逐次数+1
            if (source == 0 && slab_zeroes[i] >= 3)
                source = i;//如果source被设置，且没有被驱逐的次数大于3，则这个
                           //slabclass_t被设置为有多余的内存页。
        } else {
            //如果diff!=0或者内存页数小于等于2
            slab_zeroes[i] = 0;//清空没有被驱逐的次数
            if (evicted_diff > evicted_max) {
                evicted_max = evicted_diff;
                highest_slab = i;
            }
        }
        evicted_old[i] = evicted_new[i];//更新evicted_old数组
    }

    /* Pick a valid destination */
    if (slab_winner != 0 && slab_winner == highest_slab) {
        //如果slab_winner被设置且等于这次的highest_slab
        slab_wins++;
        if (slab_wins >= 3)//如果slab_winner被选中三次，则被选为最需要内存的slabclass
            dest = slab_winner;
    } else {//否则
        slab_wins = 1;更新slab_wins=1
        slab_winner = highest_slab;//slab_winner更新为highest_slab。
    }

    if (source && dest) {//同时设置了source和dest才返回1，进行内存迁移操作。
        *src = source;
        *dst = dest;
        return 1;
    }
    return 0;
}
```
由于这个函数处于一个while循环中，所以执行的次数会比较频繁，可以说是一秒一次（sleep(1))，所以需要进行频率控制，全局变量current_time由libevent时间事件每1秒更新一次。所以两次执行函数主体间隔必须操过10秒。函数主体主要是选出有多余内存页和最缺少内存页的slabclass_t。
1. 对于选有多余内存页的slabclass_t很简单，主要没有被驱逐的次数超过三次以上且内存页大于2即可。
2. 对于最需要内存页的slabclass_t的选择，主要连续三次被选为驱逐次数最多即可。

如果选出了source和dest，则调用slabs\_reassign函数，slabs\_reassign函数调用do_slabs_reassign函数：
```
enum reassign_result_type {
    REASSIGN_OK=0, REASSIGN_RUNNING, REASSIGN_BADCLASS, REASSIGN_NOSPARE,
    REASSIGN_SRC_DST_SAME
};
//do_slabs_reassign函数返回类型
static enum reassign_result_type do_slabs_reassign(int src, int dst) {
    if (slab_rebalance_signal != 0)
        return REASSIGN_RUNNING;

    if (src == dst)
        return REASSIGN_SRC_DST_SAME;

    /* Special indicator to choose ourselves. */
    if (src == -1) {
        src = slabs_reassign_pick_any(dst);
        /* TODO: If we end up back at -1, return a new error type */
    }

    if (src < POWER_SMALLEST || src > power_largest ||
        dst < POWER_SMALLEST || dst > power_largest)
        return REASSIGN_BADCLASS;

    if (slabclass[src].slabs < 2)
        return REASSIGN_NOSPARE;
    //设置全局变量s_clsid和d_clsid属性，用于在rebalance线程处理
    slab_rebal.s_clsid = src;
    slab_rebal.d_clsid = dst;

    slab_rebalance_signal = 1;
    pthread_cond_signal(&slab_rebalance_cond);//唤醒rebalance线程

    return REASSIGN_OK;
}
```
这个函数主要是判断src和dst是否恰当。对于src==-1的情形，是在automove=2的情形下才会出现的，所以就任选一个src。假设src和dst都恰当，则设置全局变量slab_rebal的s_clsid和d_clsid，并设置slab_rebalance_signal=1，这在rebalance线程有使用到，表示唤醒这个rebalance线程，最后唤醒rebalance线程。

# rebalance线程

----

接下来看下rebalance线程，它是和maintenance线程一起被创建的，一开始处于睡眠状态中，等待被唤醒;
```
static void *slab_rebalance_thread(void *arg) {
    int was_busy = 0;
    /* So we first pass into cond_wait with the mutex held */
    mutex_lock(&slabs_rebalance_lock);

    while (do_run_slab_rebalance_thread) {
        if (slab_rebalance_signal == 1) {
            if (slab_rebalance_start() < 0) {//这个函数主要是设置slab_rebal这个全局变量
                /* Handle errors with more specifity as required. */
                slab_rebalance_signal = 0;
            }

            was_busy = 0;
        } else if (slab_rebalance_signal && slab_rebal.slab_start != NULL) {
           // 如果slab_rebalance_signal=2时，这里主要是为了重复进入move函数
            was_busy = slab_rebalance_move();
        }

        if (slab_rebal.done) {
            slab_rebalance_finish();
        } else if (was_busy) {
            /* Stuck waiting for some items to unlock, so slow down a bit
             * to give them a chance to free up */
            usleep(50);
        }
        //一开始初始化时，rebalance线程睡眠于此
        if (slab_rebalance_signal == 0) {
            /* always hold this lock while we're running */
            pthread_cond_wait(&slab_rebalance_cond, &slabs_rebalance_lock);
        }
    }
    return NULL;
}
```
这个函数为rebalance线程函数，一开始时，slab_rebalance_signal为0，睡眠在pthread_cond_wait函数中。当被slabs_reassign函数唤醒时，则进入slab_rebalance_start函数，主要是设置需要转移的源slabclass_t和目的slabclass_t的id，以及开始迁移的初始item
```
static int slab_rebalance_start(void) {
    slabclass_t *s_cls;
    int no_go = 0;

    pthread_mutex_lock(&slabs_lock);
    //判断src和dst是否有效
    if (slab_rebal.s_clsid < POWER_SMALLEST ||
        slab_rebal.s_clsid > power_largest  ||
        slab_rebal.d_clsid < POWER_SMALLEST ||
        slab_rebal.d_clsid > power_largest  ||
        slab_rebal.s_clsid == slab_rebal.d_clsid)
        no_go = -2;
    //源slabclass_t
    s_cls = &slabclass[slab_rebal.s_clsid];
    //将slabclass_t[dst]的内存页数可能增加
    if (!grow_slab_list(slab_rebal.d_clsid)) {
        no_go = -1;
    }

    if (s_cls->slabs < 2)//源slabclass_t自己不够内存页
        no_go = -3;

    if (no_go != 0) {
        pthread_mutex_unlock(&slabs_lock);
        return no_go; /* Should use a wrapper function... */
    }

    s_cls->killing = 1;//默认把第一个内存页迁移到slabclass_t[dst]

    slab_rebal.slab_start = s_cls->slab_list[s_cls->killing - 1];//第一个item
    slab_rebal.slab_end   = (char *)slab_rebal.slab_start +
        (s_cls->size * s_cls->perslab);//内存页结束位置
    slab_rebal.slab_pos   = slab_rebal.slab_start;//目前迁移的位置
    slab_rebal.done       = 0;

    /* Also tells do_item_get to search for items in this slab */
    slab_rebalance_signal = 2;//这这个设置主要是为了slab_rebalance_thread线程函数不再进入slab_rebalance_start函数中。

    if (settings.verbose > 1) {
        fprintf(stderr, "Started a slab rebalance\n");
    }

    pthread_mutex_unlock(&slabs_lock);

    STATS_LOCK();
    stats.slab_reassign_running = true;
    STATS_UNLOCK();

    return 0;
}
```
slab_rebalance_start函数主要是设置slab_rebal这个全局变量，因为在后面的move函数进行真正的迁移时有用到：
```
static int slab_rebalance_move(void) {
    slabclass_t *s_cls;
    int x;
    int was_busy = 0;
    int refcount = 0;
    uint32_t hv;
    void *hold_lock;
    enum move_status status = MOVE_PASS;

    pthread_mutex_lock(&slabs_lock);

    s_cls = &slabclass[slab_rebal.s_clsid];//源slabclass_t
    //slab_bulk_check为一次回收的item数量，默认为1
    for (x = 0; x < slab_bulk_check; x++) {
        hv = 0;
        hold_lock = NULL;
        item *it = slab_rebal.slab_pos;//本次回收的item内存位置
        status = MOVE_PASS;
        if (it->slabs_clsid != 255) {
            /* ITEM_SLABBED can only be added/removed under the slabs_lock */
            if (it->it_flags & ITEM_SLABBED) {//说明是空闲的item，直接从slots删除即可。
                /* remove from slab freelist */
                if (s_cls->slots == it) {
                    s_cls->slots = it->next;
                }
                if (it->next) it->next->prev = it->prev;
                if (it->prev) it->prev->next = it->next;
                s_cls->sl_curr--;
                status = MOVE_FROM_SLAB;
            } else if ((it->it_flags & ITEM_LINKED) != 0) {
                //假如这个Item处于链表中
                hv = hash(ITEM_key(it), it->nkey);
                if ((hold_lock = item_trylock(hv)) == NULL) {
                    status = MOVE_LOCKED;//这个item被其他worker线程锁住了
                } else {
                    refcount = refcount_incr(&it->refcount);
                    if (refcount == 2) { /* item is linked but not busy */
                        /* Double check ITEM_LINKED flag here, since we're
                         * past a memory barrier from the mutex. */
                        if ((it->it_flags & ITEM_LINKED) != 0) {
                            status = MOVE_FROM_LRU;
                        } else {
                            /* refcount == 1 + !ITEM_LINKED means the item is being
                             * uploaded to, or was just unlinked but hasn't been freed
                             * yet. Let it bleed off on its own and try again later */
                            status = MOVE_BUSY;
                        }
                    } else {
                        if (settings.verbose > 2) {
                            fprintf(stderr, "Slab reassign hit a busy item: refcount: %d (%d -> %d)\n",
                                it->refcount, slab_rebal.s_clsid, slab_rebal.d_clsid);
                        }
                        status = MOVE_BUSY;
                    }
                    /* Item lock must be held while modifying refcount */
                    if (status == MOVE_BUSY) {
                        refcount_decr(&it->refcount);
                        item_trylock_unlock(hold_lock);
                    }
                }
            }
        }

        switch (status) {
            case MOVE_FROM_LRU:
                /* Lock order is LRU locks -> slabs_lock. unlink uses LRU lock.
                 * We only need to hold the slabs_lock while initially looking
                 * at an item, and at this point we have an exclusive refcount
                 * (2) + the item is locked. Drop slabs lock, drop item to
                 * refcount 1 (just our own, then fall through and wipe it
                 */
                pthread_mutex_unlock(&slabs_lock);
                do_item_unlink(it, hv);
                item_trylock_unlock(hold_lock);
                pthread_mutex_lock(&slabs_lock);
            case MOVE_FROM_SLAB:
                it->refcount = 0;
                it->it_flags = 0;
                it->slabs_clsid = 255;
                break;
            case MOVE_BUSY:
            case MOVE_LOCKED:
                slab_rebal.busy_items++;
                was_busy++;
                break;
            case MOVE_PASS:
                break;
        }

        slab_rebal.slab_pos = (char *)slab_rebal.slab_pos + s_cls->size;
        if (slab_rebal.slab_pos >= slab_rebal.slab_end)
            break;
    }

    if (slab_rebal.slab_pos >= slab_rebal.slab_end) {
        /* Some items were busy, start again from the top */
        if (slab_rebal.busy_items) {
            slab_rebal.slab_pos = slab_rebal.slab_start;
            slab_rebal.busy_items = 0;
        } else {
            slab_rebal.done++;
        }
    }

    pthread_mutex_unlock(&slabs_lock);

    return was_busy;
}
```
这个函数主要就是将源slabclass_t的item一个一个回收进slabclass[src]的第一个内存页，这样在slab_rebanlance_finish函数中才可以把这个内存页迁移到slabclass[dst]中
```
static void slab_rebalance_finish(void) {
    slabclass_t *s_cls;
    slabclass_t *d_cls;

    pthread_mutex_lock(&slabs_lock);

    s_cls = &slabclass[slab_rebal.s_clsid];
    d_cls   = &slabclass[slab_rebal.d_clsid];

    /* 因为第一个内存页被取走了，所以把这个源slabclass_t的最后一个内存页赋给第一个内存页*/
    s_cls->slab_list[s_cls->killing - 1] =
        s_cls->slab_list[s_cls->slabs - 1];
    s_cls->slabs--;
    s_cls->killing = 0;
    //初始化这个迁移的内存页
    memset(slab_rebal.slab_start, 0, (size_t)settings.item_size_max);
    //slabclass_t[dst]接收这个内存页
    d_cls->slab_list[d_cls->slabs++] = slab_rebal.slab_start;
    //将这个迁移的内存页按slabclass_t[dst]的item大小分割这个内存页
    split_slab_page_into_freelist(slab_rebal.slab_start,
        slab_rebal.d_clsid);

    //还原slab_rebal这个全局变量，
    slab_rebal.done       = 0;
    slab_rebal.s_clsid    = 0;
    slab_rebal.d_clsid    = 0;
    slab_rebal.slab_start = NULL;
    slab_rebal.slab_end   = NULL;
    slab_rebal.slab_pos   = NULL;
    //内存页迁移结束
    slab_rebalance_signal = 0;

    pthread_mutex_unlock(&slabs_lock);

    STATS_LOCK();
    stats.slab_reassign_running = false;
    stats.slabs_moved++;
    STATS_UNLOCK();

    if (settings.verbose > 1) {
        fprintf(stderr, "finished a slab move\n");
    }
}
```
这样一次内存页迁移就结束了，rebalance线程重新睡眠在pthread_cond_wait函数中，等待下一次被唤醒。


















