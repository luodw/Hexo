title: memcache源码分析之lru维护线程
date: 2016-01-19 19:54:09
tags:
- memcache
categories:
- memcache
toc: true

---

memcache和数据有关的数据结构有三个slab,lru和哈希表,所以在memcache运行过程中,需要不断维护这三个数据结构,以免降低性能.之前两篇文章,分析维护哈希表的扩容线程和维护slab的平衡线程.今天这篇文章主要分析了维护lru,即清除lru队列中不恰当的item.这部分较难,因为这部分在版本1.2.23版本开始,重写了实现,网上源码分析较少,所以看得有点吃力,今天把知识点好好整理下.

# 真实的lru队列

----

直到看了这部分内容,我才真正认识了lru,虽然叫lru,但是这个真正的lru是不一样的,Linux内核和leveldb都有lru缓冲区,这个是按最近最少访问策略来剔除缓存节点,这种模式是,如果某个节点被访问,则先删除,再重新插入,这样就可以移到最新的数据区.但是memcache并不是这样,在do_item_get函数里面即使访问一个节点,也没有更新它的位置.但是memcache有把缓存数据分为hot,warm和cold三种,hot都是最新的数据,当内存不足时,最终删除的是cold数据区.

我猜测memcache这样设计的理由是:memcache在实际使用中,作为缓存数据库,那么它存储的都是最经常访问的数据,所以它整体就是最热的数据区

一开始看memcache源码,可能会觉得lru就是和slabclass_t数组一一对应,即有多少个slabclass_t,就有多少个lru队列.但是看到最后才发现原来每一个lru有分为hot,warm,cold三种,如下分析:slabclass_t数组最大为64,即0-63.但是lru数组最大值为255,为啥了?
```
#define HOT_LRU 0//hot数据区
#define WARM_LRU 64//warm数据区
#define COLD_LRU 128//cold数据区
#define NOEXP_LRU 192//没有过期时间数据区
static unsigned int lru_type_map[4] = {HOT_LRU, WARM_LRU, COLD_LRU, NOEXP_LRU};

#define CLEAR_LRU(id) (id & ~(3<<6))//最原始的数据区,即hot数据区

#define LARGEST_ID POWER_LARGEST//lru数组最大值256,即0-255
```
因为一个slabclass\_t对应三条lru队列,即hot,warm,cold lru.一般函数给出的是slabclass\_t的索引id,也就是hot lru的索引,如果要操作warm lru队列,则需要id |= WARM\_LRU,如果要操作cold lru,则只需要id |= COLD\_LRU.因为id值的范围为[0,63],即最大值63为0011 1111,而64二进制为0100 0000,id | 64,即id+64,128二进制为1000 0000,id | 128 ,即id+128,192二进制为1100 0000,id | 192即id+192.因为id最大值为63,所以lru最大值为255.就是说当hot lru的索引为8时,warm lru索引为72,cold lru索引为136,noexp_lru索引为200.

当然,
1. 每次插入数据时,总是插在hot lru队列中,因为最新的数据,在一定程度上就是最热的数据.
2. warm lru的数据来源与cold lru,当cold lru的数据被访问活跃时,则被提到warm区;
3. hot和warm lru默认各占slabclass_t的32%,可以通过memcached开启时,通过-o设置.cold lru则为剩下的部分.当hot和warm lru超出32%之后,则被踢到cold lru中.

# memcache惰性删除机制

----

memcache并没有直接删除过期的键值对,而是采取惰性删除的机制.即键值对到期之后,并没有调用item_unlink删除,而是继续占着lru和哈希表,等到如下情况才把item删除:
1. 当调用do_item_get函数时,先判断获取到的item是否过期,过期则删除,返回null;
2. 当调用do_item_alloc时,如果从slab不能分到内存,则会进行一次检查是否有过期的item,有则直接用这个过期的item存储目前这个键值对.如果没有,则直接从cold lru尾部删除一个item,供目前这个键值对使用.
3. 使用maintenance和crawler线程,删除过期的item.

而键值对过期也有两种情况:
1. 在插入item时,设定的过期时间到期了;
2. 调用flush_all命令,会将flush_all命令之前创建的item都标注为过期了.真正实现更新settings.oldest_live,即在这创建,更新的Item都失效.

## 惰性删除之do_item_get

之前说到,当memcache调用do\_item\_get函数获取键值对时,会先判断获取的键值对是否过期,如果是返回null,并删除这个Item,来看下源码:
```
item *do_item_get(const char *key, const size_t nkey, const uint32_t hv) {
    item *it = assoc_find(key, nkey, hv);
    if (it != NULL) {
        refcount_incr(&it->refcount);//找到这个item,这个item引用+1
     }
    int was_found = 0;

    if (it != NULL) {//item不为空
        if (is_flushed(it)) {//这个item是否在flush_all之前,如果是,则删除
            do_item_unlink(it, hv);
            do_item_remove(it);
            it = NULL;
            if (was_found) {
                fprintf(stderr, " -nuked by flush");
            }
        //这个item是否过期,过期则删除
        } else if (it->exptime != 0 && it->exptime <= current_time) {
            do_item_unlink(it, hv);
            do_item_remove(it);
            it = NULL;
            if (was_found) {
                fprintf(stderr, " -nuked by expire");
            }
        } else {//如果这个item没有在flush_all之前也没有过期,则标注为活跃item
        //以及被获取
            it->it_flags |= ITEM_FETCHED|ITEM_ACTIVE;
            DEBUG_REFCNT(it, '+');
        }
    }

    if (settings.verbose > 2)
        fprintf(stderr, "\n");

    return it;
}
```

## 惰性删除之do_item_alloc

当worker线程要插入一个键值对时,需要先分配item内存.但是如果此时slab内存全都已使用完毕,那么这时先检查是否有过期的item,有则将过期的item直接给插入的键值对使用.如果没有,则将cold lru最后一个强制删除,留出空间.
```
item *do_item_alloc(char *key, const size_t nkey, const int flags,
           const rel_time_t exptime, const int nbytes,
           const uint32_t cur_hv) {
		/*
		.........
		*/
	 for (i = 0; i < 5; i++) {
        /* Try to reclaim memory first */
        if (!settings.lru_maintainer_thread) {
            //如果没有开启maintainer线程,则先看下cold lru是否有过期item回收,有则直接重复利用
            lru_pull_tail(id, COLD_LRU, 0, false, cur_hv);
        }
        it = slabs_alloc(ntotal, id, &total_chunks);//分配内存
        if (settings.expirezero_does_not_evict)
            total_chunks -= noexp_lru_size(id);
        if (it == NULL) {//分不到内存,如果开启maintainer,则看下hot,warm,cold lru是否有过期item
            if (settings.lru_maintainer_thread) {
                lru_pull_tail(id, HOT_LRU, total_chunks, false, cur_hv);
                lru_pull_tail(id, WARM_LRU, total_chunks, false, cur_hv);
                lru_pull_tail(id, COLD_LRU, total_chunks, true, cur_hv);
            } else {//如果没开启,则强制删除cold lru最后一个item
                lru_pull_tail(id, COLD_LRU, 0, true, cur_hv);
            }
        } else {
            break;
        }
    }
		/*
		..........
		*/
```
当为item分配内存时,先是分析cold lru是否有过期item,有则回收.如果没有过期item,而且开启maintainer线程,则分析hot , warm lru是否有过期item以及直接删除cold lru最后一个item.lru\_pull\_tail函数用于分析hot,warm,cold lru是否有过期电费item,后面再分析.

# crawler线程

----

memcache支持手动和自动两种爬虫删除过期item.手动即在客户端中输入命令,自动即开启maintainer线程,接下来先介绍手动方式.当要开启crawler线程,可以通过memcached -o lru\_crawler开启也可以在命令行中开启.但是一搬情况是用memcached开启时添加选项memcached -o lru\_crawler,lru_maintainer同时开启两个线程,crawler线程开启之后睡眠,等待被唤醒;maintainer线程则不断对lru分析lru和warm使用空间是否已满,满则踢到cold lru.还分析warm和cold lru之间item的交换等等,最后唤醒crawler线程.

客户端也可以通过命令,指定对哪个lru爬虫;
1. lru_crawler <enable|disable> 启动或者停止一个lru爬虫线程;
2. lru_crawler crawler<classid,classid,classid | all> 可以用2,3,6这样的列表指定对哪个lru队列进行清楚,也可以对所有队列清楚.
3. lru_crawler sleep<microsecond> 由于lru爬虫时会占用锁,影响worker线程正常作业,所以需要时不时休息下,默认是100微妙
4. lru_crawler tocrawl <32u> lru可能会有很多item失效,如果一个个去爬虫,则会影响其他worker线程工作,所以就可以用这个这只一次最多爬num个item.

##  crawler线程开启

memcached -o lru_crawler或者命令行lru\_crawler enable可以调用start\_item\_crawler\_thread开启crawler线程,线程函数为:
```
static void *item_crawler_thread(void *arg) {
    int i;
    int crawls_persleep = settings.crawls_persleep;

    pthread_mutex_lock(&lru_crawler_lock);
    if (settings.verbose > 2)
        fprintf(stderr, "Starting LRU crawler background thread\n");
    while (do_run_lru_crawler_thread) {
    pthread_cond_wait(&lru_crawler_cond, &lru_crawler_lock);
    /*
    .........
    */
```
刚开启crawler线程时,先是睡眠,等待被唤醒.我们来假设下客户端命令此时发来爬虫请求,lru\_crawler tocrawl 20,lru\_crawler crawler 2,4,6即对原始id为2,4,6的lru队列爬虫20个item,此时对9个lru队列爬虫,因为每个原始id都有三个lru队列(hot,warm,cold).lru\_crawler tocrawl 20只是简单的settings.lru_crawler_tocrawl属性,lru\_crawler crawler命令调用的是lru_crawler_crawl(char *slabs)函数:
```
enum crawler_result_type lru_crawler_crawl(char *slabs) {
    char *b = NULL;
    uint32_t sid = 0;
    int starts = 0;
    uint8_t tocrawl[MAX_NUMBER_OF_SLAB_CLASSES];
    if (pthread_mutex_trylock(&lru_crawler_lock) != 0) {
        return CRAWLER_RUNNING;
    }

    /* 初始化tocrawl数组,存储被爬虫lru索引 */
    memset(tocrawl, 0, sizeof(uint8_t) * MAX_NUMBER_OF_SLAB_CLASSES);
    if (strcmp(slabs, "all") == 0) {//分析crawler命令后来的参数,如果是all
        for (sid = 0; sid < MAX_NUMBER_OF_SLAB_CLASSES; sid++) {
            tocrawl[sid] = 1;//对所有的lru队列爬虫
        }
    } else {
        for (char *p = strtok_r(slabs, ",", &b);//索引列表
             p != NULL;
             p = strtok_r(NULL, ",", &b)) {

            if (!safe_strtoul(p, &sid) || sid < POWER_SMALLEST
                    || sid >= MAX_NUMBER_OF_SLAB_CLASSES-1) {
                pthread_mutex_unlock(&lru_crawler_lock);
                return CRAWLER_BADCLASS;
            }
            tocrawl[sid] = 1;
        }
    }

    for (sid = POWER\_SMALLEST; sid < MAX\_NUMBER_OF_SLAB_CLASSES; sid++) {
        if (tocrawl[sid])
            //给原始id为sid的三个队列添加爬虫item
            starts += do_lru_crawler_start(sid, settings.lru_crawler_tocrawl);
    }
    if (starts) {
        //唤醒crawler线程
        pthread_cond_signal(&lru_crawler_cond);
        pthread_mutex_unlock(&lru_crawler_lock);
        return CRAWLER_OK;
    } else {
        pthread_mutex_unlock(&lru_crawler_lock);
        return CRAWLER_NOTSTARTED;
    }
}
```
 
这个函数先解析出lru\_crawler crawler命令之后的参数,然后分别标记哪些lru需要爬虫,调用do\_lru\_crawler\_start函数安装一个爬虫item,然后唤醒crawler线程爬虫.爬虫item和正常的Item长的很像,但是不存储数据,我们看下它的定义

```
typedef struct {
    struct _stritem *next;
    struct _stritem *prev;
    struct \_stritem \*h\_next;    /* hash chain next */
    rel_time_t      time;       /* least recent access */
    rel_time_t      exptime;    /* expire time */
    int             nbytes;     /* size of data */
    unsigned short  refcount;
    uint8_t         nsuffix;    /* length of flags-and-length string */
    uint8\_t         it\_flags;   /* ITEM_* above */
    uint8\_t         slabs_clsid;/* which slab class we're in */
    uint8_t         nkey;       /* key length, w/terminating null and padding */
    uint32_t        remaining;  /* Max keys to crawl per slab per invocation */
} crawler;
```

就最后一个属性和正常item不一样,其他都一样,所以二者指针可以相互转换,不影响属性值.先来思考一个问题,之前有说过可以设置每次对lru爬item的个数,但是lru为一个链表队列,不支持随机存储,每次访问一个Item都必须从head开始,一个一个访问,那么怎么记录哪些item已经访问,哪些没有访问.memcache设计了上述的crawler爬虫item,给每个lru队列尾端安装一个crawler,然后每次访问一个Item时,crawler前进一个位置.下次爬虫时,直接从crawler节点开始,往前走即可.下面图片来自网络,很好解释了crawler爬虫过程:
![crawler爬虫过程](http://7xjnip.com1.z0.glb.clouddn.com/ldw-%E9%80%89%E5%8C%BA_054.png "")

先看下是如何安装爬虫线程
```
static int do_lru_crawler_start(uint32\_t id, uint32\_t remaining) {
    int i;
    uint32_t sid;
    uint32_t tocrawl[3];
    int starts = 0;
    //找到id的三个lru队列,分别安装crawler
    tocrawl[0] = id | HOT_LRU;
    tocrawl[1] = id | WARM_LRU;
    tocrawl[2] = id | COLD_LRU;

    for (i = 0; i < 3; i++) {
        sid = tocrawl[i];
        pthread_mutex_lock(&lru_locks[sid]);
        if (tails[sid] != NULL) {
            if (settings.verbose > 2)
                fprintf(stderr, "Kicking LRU crawler off for LRU %d\n", sid);
            crawlers[sid].nbytes = 0;
            crawlers[sid].nkey = 0;
            crawlers[sid].it_flags = 1; /* 表示这个crawler已开启. */
            crawlers[sid].next = 0;
            crawlers[sid].prev = 0;
            crawlers[sid].time = 0;
            crawlers[sid].remaining = remaining;
            crawlers[sid].slabs_clsid = sid;
            crawler_link_q((item *)&crawlers[sid]);//插索引为sid的lru队列的尾端
            crawler_count++;//本次爬虫的lru个数加1
            starts++;
        }
        pthread_mutex_unlock(&lru_locks[sid]);
    }
    /*
     ......................
    */
```
安装好之后,接下来会唤醒crawler线程,线程开始爬虫
```
static void *item_crawler_thread(void *arg) {
int i;
    int crawls_persleep = settings.crawls_persleep;

    pthread_mutex_lock(&lru_crawler_lock);
    if (settings.verbose > 2)
        fprintf(stderr, "Starting LRU crawler background thread\n");
    while (do_run_lru_crawler_thread) {
    pthread_cond_wait(&lru_crawler_cond, &lru_crawler_lock);

    while (crawler_count) {
        item *search = NULL;
        void *hold_lock = NULL;

        for (i = POWER_SMALLEST; i < LARGEST_ID; i++) {
            if (crawlers[i].it_flags != 1) {
                continue;
            }
            pthread_mutex_lock(&lru_locks[i]);
            //crawler\_crawl_q函数返回crawler前一个item,并把crawler向前移动一个位置
            search = crawler_crawl_q((item *)&crawlers[i]);
            if (search == NULL ||
                (crawlers[i].remaining && --crawlers[i].remaining < 1)) {
            //如果search为空或者remaining(一开始设置为爬item的个数)减到为0.
            //则说明已爬了一条lru
                if (settings.verbose > 2)
                    fprintf(stderr, "Nothing left to crawl for %d\n", i);
                crawlers[i].it_flags = 0;//这个crawler关闭
                crawler_count--;//爬虫lru个数减1
                crawler_unlink_q((item *)&crawlers[i]);//删除这个crawler
                pthread_mutex_unlock(&lru_locks[i]);
                pthread_mutex_lock(&lru_crawler_stats_lock);
                crawlerstats[CLEAR_LRU(i)].end_time = current_time;
                crawlerstats[CLEAR_LRU(i)].run_complete = true;
                pthread_mutex_unlock(&lru_crawler_stats_lock);
                continue;
            }
            uint32_t hv = hash(ITEM_key(search), search->nkey);
            /* Attempt to hash item lock the "search" item. If locked, no
             * other callers can incr the refcount
             */
            if ((hold_lock = item_trylock(hv)) == NULL) {
                pthread_mutex_unlock(&lru_locks[i]);
                continue;
            }
            /* Now see if the item is refcount locked */
            if (refcount_incr(&search->refcount) != 2) {
                refcount_decr(&search->refcount);
                if (hold_lock)
                    item_trylock_unlock(hold_lock);
                pthread_mutex_unlock(&lru_locks[i]);
                continue;
            }

            /* Frees the item or decrements the refcount. */
            /* Interface for this could improve: do the free/decr here
             * instead? */
            pthread_mutex_lock(&lru_crawler_stats_lock);
            item_crawler_evaluate(search, hv, i);//这个函数用于判断这个search是否过期,过期则删除.
            pthread_mutex_unlock(&lru_crawler_stats_lock);

            if (hold_lock)
                item_trylock_unlock(hold_lock);
            pthread_mutex_unlock(&lru_locks[i]);

            if (crawls_persleep <= 0 && settings.lru_crawler_sleep) {
                //睡眠一段时间,供worker线程操作lru
                usleep(settings.lru_crawler_sleep);
                crawls_persleep = settings.crawls_persleep;
            }
        }
    }
```
这个爬虫函数对给定的lru队列一个一个爬虫,每次爬一个item,直到爬完整条Lru或者指定的item个数减为0.当所有crawler结束之后,本次爬虫就结束.

# maintainer线程

----

maintainer线程处于一个while循环中,不断进行lru表维护,即删除过期的item,以及如果hot,warm lru占有内存超过限定额度,则移至cold lru等等.执行完这些操作之后,还会唤醒crawler线程,执行爬虫删除过期item.来看下线程函数
```
static void *lru_maintainer_thread(void *arg) {
    int i;
    useconds\_t to\_sleep = MIN_LRU_MAINTAINER_SLEEP;
    rel_time\_t last\_crawler_check = 0;

    pthread_mutex_lock(&lru_maintainer_lock);
    if (settings.verbose > 2)
        fprintf(stderr, "Starting LRU maintainer background thread\n");
    while (do_run_lru_maintainer_thread) {
        int did_moves = 0;
        pthread_mutex_unlock(&lru_maintainer_lock);
        usleep(to_sleep);
        pthread_mutex_lock(&lru_maintainer_lock);

        STATS_LOCK();
        stats.lru_maintainer_juggles++;
        STATS_UNLOCK();
        /* We were asked to immediately wake up and poke a particular slab
         * class due to a low watermark being hit */
        if (lru_maintainer_check_clsid != 0) {
            //执行维护任务,即上述所说的
            did_moves = lru_maintainer_juggle(lru_maintainer_check_clsid);
            lru_maintainer_check_clsid = 0;
        } else {
            for (i = POWER_SMALLEST; i < MAX_NUMBER_OF_SLAB_CLASSES; i++) {
                //对每一个slabclass_t的lru执行维护任务
                did_moves += lru_maintainer_juggle(i);
            }
        }
        if (did_moves == 0) {//如果没有移动,则增加睡眠时间
            if (to_sleep < MAX_LRU_MAINTAINER_SLEEP)
                to_sleep += 1000;
        } else {
            to_sleep /= 2;//如果有hot,warm,cold有数据move,则睡眠时间减少
            if (to_sleep < MIN_LRU_MAINTAINER_SLEEP)
                to_sleep = MIN_LRU_MAINTAINER_SLEEP;
        }
        /* 当有移动时,说明lru数据需要维护,所以睡眠时间减少,如果
           没有移动,说明lru变化不大,则增长睡眠时间
        */
        if (settings.lru_crawler && last_crawler_check != current_time) {
            lru_maintainer_crawler_check();//执行lru_crawler_start函数,唤醒crawler线程
            last_crawler_check = current_time;
        }
    }
    pthread_mutex_unlock(&lru_maintainer_lock);
    if (settings.verbose > 2)
        fprintf(stderr, "LRU maintainer thread stopping\n");

    return NULL;
}
```
这个维护线程不断的维护hot,warm,cold lru,然后再唤醒crawler线程进行爬虫删除.最后再看下lru维护函数
```
static int lru_maintainer_juggle(const int slabs_clsid) {
//.....................
for (i = 0; i < 1000; i++) {
        int do_more = 0;
        if (lru_pull_tail(slabs_clsid, HOT_LRU, total_chunks, false, 0) ||
            lru_pull_tail(slabs_clsid, WARM_LRU, total_chunks, false, 0)) {
            do_more++;
        }
        do_more += lru_pull_tail(slabs_clsid, COLD_LRU, total_chunks, false, 0);
        if (do_more == 0)
            break;
        did_moves++;
    }
    return did_moves;
//这是维护线程调用的一个函数,在这个函数中调用lru_pull_tail函数进行维护
static int lru_pull_tail(const int orig_id, const int cur_lru,
        const unsigned int total_chunks, const bool do_evict, const uint32_t cur_hv) {
    item *it = NULL;
    int id = orig_id;
    int removed = 0;
    if (id == 0)
        return 0;

    int tries = 5;
    item *search;
    item *next_it;
    void *hold_lock = NULL;
    unsigned int move_to_lru = 0;
    uint64_t limit;

    id |= cur_lru;//获取真实的lru id. 原始orig_id为hot lru id
    pthread_mutex_lock(&lru_locks[id]);
    search = tails[id];//这个lru最后一个item
    /* We walk up *only* for locked items, and if bottom is expired. */
    for (; tries > 0 && search != NULL; tries--, search=next_it) {
        /* we might relink search mid-loop, so search->prev isn't reliable */
        next_it = search->prev;
        if (search->nbytes == 0 && search->nkey == 0 && search->it_flags == 1) {
            /* 是一个crawler,直接跳过 */
            tries++;
            continue;
        }
        uint32\_t\ hv = hash(ITEM\_key(search), search->nkey);//这个item的哈希值
        /* Attempt to hash item lock the "search" item. If locked, no
         * other callers can incr the refcount. Also skip ourselves. */
        if (hv == cur\_hv || (hold\_lock = item\_trylock(hv)) == NULL)//锁住这个哈希桶
            continue;
        /* Now see if the item is refcount locked */
        if (refcount_incr(&search->refcount) != 2) {
            /* Note pathological case with ref'ed items in tail.
             * Can still unlink the item, but it won't be reusable yet */
            itemstats[id].lrutail_reflocked++;
            /* In case of refcount leaks, enable for quick workaround. */
            /* WARNING: This can cause terrible corruption */
            if (settings.tail_repair_time &&
                    search->time + settings.tail_repair_time < current_time) {
                itemstats[id].tailrepairs++;
                search->refcount = 1;
                /* This will call item_remove -> item_free since refcnt is 1 */
                do_item_unlink_nolock(search, hv);
                item_trylock_unlock(hold_lock);
                continue;
            }
        }

        /* 下面这个if语句判断是否过期或者被flush */
        if ((search->exptime != 0 && search->exptime < current_time)
            || is_flushed(search)) {
            itemstats[id].reclaimed++;
            if ((search->it_flags & ITEM_FETCHED) == 0) {
                itemstats[id].expired_unfetched++;
            }
            /* refcnt 2 -> 1 */
            do_item_unlink_nolock(search, hv);
            /* refcnt 1 -> 0 -> item_free */
            do_item_remove(search);
            item_trylock_unlock(hold_lock);
            removed++;

            /* If all we're finding are expired, can keep going */
            continue;
        }

        /* If we're HOT_LRU or WARM_LRU and over size limit, send to COLD_LRU.
         * If we're COLD_LRU, send to WARM_LRU unless we need to evict
         */
        switch (cur_lru) {
            case HOT_LRU://这个case没有break,则与warm_lru共用代码
                limit = total_chunks * settings.hot_lru_pct / 100;
            case WARM_LRU:
                limit = total_chunks * settings.warm_lru_pct / 100;
                if (sizes[id] > limit) {//如果hot和warm lru区item空间利用大于32%
                    itemstats[id].moves_to_cold++;
                    move_to_lru = COLD_LRU;//移到cold lru区
                    do_item_unlink_q(search);//先从lru删除,后面会再加到cold lru中
                    it = search;
                    removed++;
                    break;
                } else if ((search->it_flags & ITEM_ACTIVE) != 0) {
                    /* Only allow ACTIVE relinking if we're not too large. */
                    itemstats[id].moves_within_lru++;
                    search->it_flags &= ~ITEM_ACTIVE;
                    //被访问之后,节点就active,所以更新时间,并且插入到lru最前端
                    do_item_update_nolock(search);
                    do_item_remove(search);//这里只是降低引用次数
                    item_trylock_unlock(hold_lock);
                } else {
                    /* Don't want to move to COLD, not active, bail out */
                    it = search;
                }
                break;
            case COLD_LRU:
                it = search; /* No matter what, we're stopping */
                if (do_evict) {//如果是可以删除节点
                    if (settings.evict_to_free == 0) {
                        /* Don't think we need a counter for this. It'll OOM.  */
                        //如果之前设置了不驱逐节点
                        break;
                    }
                    itemstats[id].evicted++;
                    itemstats[id].evicted_time = current_time - search->time;
                    if (search->exptime != 0)
                        itemstats[id].evicted_nonzero++;
                    if ((search->it_flags & ITEM_FETCHED) == 0) {
                        itemstats[id].evicted_unfetched++;
                    }
                    do_item_unlink_nolock(search, hv);//删除这个节点
                    removed++;
                } else if ((search->it_flags & ITEM_ACTIVE) != 0
                        && settings.lru_maintainer_thread) {
                    itemstats[id].moves_to_warm++;
                    search->it_flags &= ~ITEM_ACTIVE;//关闭active
                    move_to_lru = WARM_LRU;//移到warm lru
                    do_item_unlink_q(search);//先从这个cold lru删除
                    removed++;
                }
                break;
        }
        if (it != NULL)
            break;
    }

    pthread_mutex_unlock(&lru_locks[id]);

    if (it != NULL) {
        if (move_to_lru) {
            it->slabs\_clsid = ITEM\_clsid(it);//更细item->slabs_clsid
            it->slabs\_clsid |= move\_to_lru;//找到这个slabs_clsid实际的lru,hot 
            //warm,cold lru?
            item_link_q(it);//插入lru队列
        }//不移动,即降低引用次数
        do_item_remove(it);
        item_trylock_unlock(hold_lock);
    }

    return removed;
}
```
这个函数比较长,也比较难懂.主要就是遍历Lru队列,检查是否有过期的Item,以及lru之间item的迁移,也很符合maintainer维护线程这个名称.

lru维护抓取线程就讲到这了,总结下:
> 每一个slabclass_t都对应四个lru队列,hot,warm,cold,noexp lru,四个lru的索引相差64.
> 开启maintainer和crawler线程,可以通过memcached -o lru_crawler,lru_maintainer.
> 可以通过客户端命令指定抓取哪个lru,lru_crawler crawl <classid,classid,classid | all>
> maintainer线程主要维护hot,warm,cold lru平衡.
















