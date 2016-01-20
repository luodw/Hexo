title: memcache源码分析之哈希表维护线程
date: 2016-01-13 19:20:46
tags:
- memcache
categories:
- memcache
toc: true

---

上篇文章主要分析了客户端向memcache发送一条命令之后，服务器的执行过程。在memcache服务器中，除了有一个主线程和四个（默认）四个子线程之外，还有四个辅助线程，分别为哈希表维护线程，LRU队列抓取和维护线程，以及slab内存池维护线程。在主线程main函数中，初始化子线程之后再分别进行初始化。调用函数分别如下
1. start_assoc_maintenance_thread()
2. start_item_crawler_thread()
3. start_lru_maintainer_thread()
4. start_slab_maintenance_thread()
其中只有第一个是默认开启的，其他三个线程需要开启memcache时设置-o设置开启。

# 哈希表维护线程

-----

memcache的哈希表使用链表来解决冲突，如果数据量较小而且分布均匀，则可以达到常量时间访问。但是如果数据分布不均匀，集中在一个桶中，则会降低哈希表的查找效率。所以使用哈希表的应用程序中，都要必要的时候进行哈希表扩容，例如当哈希表中的元素个数等于哈希表大小时，进程扩容。memcache采取的扩容策略为当哈希表中元素个数大于哈希表长度*1.5时，进行扩容，每次向哈希表插入时都要进行判断。

当主线程调用start_assoc_maintenance_thread时，此时初始化hash_bulk_move全局变量，然后创建线程，执行线程函数assoc_maintenance_thread：
```
tatic void *assoc_maintenance_thread(void *arg) {

    mutex_lock(&maintenance_lock);
    while (do_run_maintenance_thread) {
        int ii = 0;

        /* There is only one expansion thread, so no need to global lock. */
        for (ii = 0; ii < hash_bulk_move && expanding; ++ii) {
        /*
         第一次执行时，由于expanding为初始值false，所以不执行for循环内部
        */
        if (!expanding) {
            /* We are done expanding.. just wait for next invocation */
            started_expanding = false;
            pthread_cond_wait(&maintenance_cond, &maintenance_lock);
            pause_threads(PAUSE_ALL_THREADS);
            assoc_expand();
            pause_threads(RESUME_ALL_THREADS);
        }
    }
    return NULL;
}
```
刚初始化时，由于expanding为false，所以此时维护线程睡眠在if语句中。当向哈希表插入数据时，将会判断是否需要进行扩容，如果是，则唤醒维护线程：
```
int assoc_insert(item *it, const uint32_t hv) {
    //。。。。
    if (! expanding && hash_items > (hashsize(hashpower) * 3) / 2) {
        assoc_start_expand();
    }
    //。。。。
```
hash_items为这个哈希表中存储元素的个数，所以这个if语句就是判断哈希表中数据是否大于哈希表长度*1.5,如果是，则调用assoc_start_expand开始扩容。
```
static void assoc_start_expand(void) {
    if (started_expanding)
        return;//先判断是否已经开始扩容，如果是，则直接返回。

    started_expanding = true;
    pthread_cond_signal(&maintenance_cond);
}
```
这个函数很简单将start_expanding设置为true，防止开启第二个扩容线程。然后唤醒这个扩容线程。有上述代码知，线程唤醒之后，先停止其他辅助线程，然后调用assoc_expand:
```
static void assoc_expand(void) {
    old_hashtable = primary_hashtable;//保存原来的哈希表
    //为新的哈希表分配空间
    primary_hashtable = calloc(hashsize(hashpower + 1), sizeof(void *));
    if (primary_hashtable) {
        if (settings.verbose > 1)
            fprintf(stderr, "Hash table expansion starting\n");
        hashpower++;//更新hashpower
        expanding = true;//设置expanding，表示正在进行扩容
        expand_bucket = 0;//从第0个桶开始迁移
        STATS_LOCK();
        //更新全局状态信息
        stats.hash_power_level = hashpower;
        stats.hash_bytes += hashsize(hashpower) * sizeof(void *);
        stats.hash_is_expanding = 1;
        STATS_UNLOCK();
    } else {
        primary_hashtable = old_hashtable;
        /* 如果分配内存失败，继续用原来的哈希表. */
    }
}
```
assoc_expand函数为新的哈希表分配内存空间，然后更新一些全局变量，这个函数结束之后，最后回到assoc_maintenance_thread线程函数中的while循环。这时由于设置了expanding，所以进入扩容步骤代码:
```
static void *assoc_maintenance_thread(void *arg) {

    mutex_lock(&maintenance_lock);
    while (do_run_maintenance_thread) {
        int ii = 0;

        /* 因为只有一个扩容线程，所以没必要锁住这个哈希表 */
        //这个hash_bulk_move表示一次将old哈希中的一个链表迁移到新的哈希表中，主要是给工作
        //线程腾出锁
        for (ii = 0; ii < hash_bulk_move && expanding; ++ii) {
            item *it, *next;
            int bucket;
            void *item_lock = NULL;

            if ((item_lock = item_trylock(expand_bucket))) {//获取第expand_bucket个链表的锁
                    for (it = old_hashtable[expand_bucket]; NULL != it; it = next) {
                        next = it->h_next;//迭代链表
                        //这个item在新哈希表中的桶
                        bucket = hash(ITEM_key(it), it->nkey) & hashmask(hashpower);
                        it->h_next = primary_hashtable[bucket];//这个item存入新的哈希表
                        primary_hashtable[bucket] = it;
                    }
                    //old哈希表第expand_bucket个桶置空
                    old_hashtable[expand_bucket] = NULL;

                    expand_bucket++;//更新expand_bucket，指向下一个迁移的桶
                    if (expand_bucket == hashsize(hashpower - 1)) {//如果最后一个桶已迁移完毕
                        expanding = false;//取消扩容标识
                        free(old_hashtable);//回收old哈希表空间
                        STATS_LOCK();//更新全局信息
                        stats.hash_bytes -= hashsize(hashpower - 1) * sizeof(void *);
                        stats.hash_is_expanding = 0;
                        STATS_UNLOCK();
                        if (settings.verbose > 1)
                            fprintf(stderr, "Hash table expansion done\n");
                    }

            } else {//未获取锁，则休息10秒，等待工作线程释放
                usleep(10*1000);
            }

            if (item_lock) {
                item_trylock_unlock(item_lock);
                item_lock = NULL;
            }
        }

        if (!expanding) {
```
看到这个扩容线程，我深深体会到哈希表可以这么支持高并发。
1. 首先在哈希表上加锁时，是加在每个桶上，而不是整个哈希表，这样可以支持多个线程操作一个哈希表中的不同桶；
2. 其次在扩容时，并不是一次性将所有数据从旧的哈希表迁移到新的哈希表，而是一次性迁移一个桶，这样可以避免锁住整个哈希表，导致工作线程阻塞；当迁移时，加锁，释放锁，这样其他工作线程在释放锁的瞬间还可以获取锁，操作哈希表。
当最后一个桶迁移之后，重新进入while循环，此时expanding被置为false，所以此时和线程初始化时是一模一样的，重新睡眠在pthread_cond_wait(&maintenance\_cond, &maintenance_lock);中。等待被唤醒，执行下一次扩容。

memcache哈希表维护线程主要做的就是当哈希表元素数量和哈希表大小达到一定比例时，进行哈希表扩容。下篇将介绍slab平衡线程。





























