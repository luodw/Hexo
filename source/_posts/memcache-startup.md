title: memcache启动过程以及线程模型
date: 2016-01-11 10:56:43
tags:
- memcache
categories:
- memcache

toc: true

---

前两篇文章，我分析了slab内存分配和item数据存储。接下来这篇文章，先分析下memcache的启动流程，这也是一个软件的整体框架。然后主要分析下memcache的线程模型。

# memcache的启动过程

---

memcache是用纯c语言开发的，所以要查看启动过程，首先要找到main函数，然后一步一步往下执行。memcache的启动过程大致如下：
1. 初始化全局变量setting。memcache没有配置文件，所有的设置都是通过启动时跟在memcache后面的参数设置的。
2. 设置系统的参数信息，例如设置产生的core文件以及core文件的最大值。设置memcache能打开的最大文件描述符个数，也就是memcache并发的连接数。
3. 设置用户。 如果是普通用户执行，则无需设置用户选项，如果是root用户，必须设置用户选项。
4. 先忽略SIGHUP信号，然后开启守护进程的设置。这里解释下为什么要忽略SIGHUP信号。因为在daeonize函数里面，父进程先fork一个子进程p1，然后设置setsid。此时p1为会话头进程。因为这个会话头进程可能再次分配到一个控制终端，所以p1也执行一次fork，产生p1的子进程p2，然后p1退出，此时的p2不是会话的头进程，也就不会获取终端。但是之前的p1是会话头进程，他的退出会给他的子进程p2发送SIGHUP信号，而SIGHUP信号默认是退出程序，所以必须捕获忽略。而一开始fork时，子进程和父进程的信号处理函数指针是一样的，所以在父进程设置SIGHUP信号处理程序，子进程也是有影响的。
5. 通过stats_init,assoc_init,conn_init,slabs_init分别初始化memcache的状态信息，哈希表，连接数和slab内存分配信息。
6. 忽略SIGPIPE信号 因为当客户端向服务器发送FIN时，此时服务器缓冲区为空时，read调用将返回0，表示对端连接关闭。如果发送缓冲区没问题，第一次调用write会正确发送，但会导致客户端发送一个重置报文RST。第二次再调用writw(假设在收到RST之后)，则会产生SIGPIPE信号，导致进程退出。所以为了以防万一，必须忽略SIGPIPE信号。
7. 开启工作线程，后面详细介绍这个。
8. 接下来就是开启四个辅助线程，维护哈希表，slab,item四个公共管理数据的部分。但是这个四个线程会阻塞在一个条件变量上。
9. 初始化时钟事件 libevent也可以一个时钟事件。
10. 然后是网络模块  即设置监听TCP，UDP,UNIX域套接字。
11. 开启主线程循环  即开始轮询监听服务器端套接字，等待客户端的连接到来。

# 开启多线程 

----

接下来，我们看下memcache是如何执行工作线程初始化的，首先还是先给出先模型：
![线程模型](http://7xjnip.com1.z0.glb.clouddn.com/20150114093937432.jpeg "")
先介绍下memcache接收到一个客户请求之后，是如何传递给子线程的。
1. 主线程主要是监听服务器端套接字，等待客户端的连接到来，子线程已经完成初始化，并且处于loop中，监听的套接字有与主线程通信管道的读端。
2. 假如此时来了一个客户端，主线程将选择一个空闲的子线程，并将这个fd封装成一个CQ_ITEM，然后将这个CQ_ITEM插入这个子线程的CQ_ITEM链表，最后给这个子线程的管道写端写入一个字符'c'；
3. 子线程在一次轮询中，得知管道可读，于是读取管道，如果读取的是字符'c'，则为这个客户端新建一个conn,并将这个客户端的套接字加入libevent事件循环中。之后，这个客户端就由这个子线程负责通信了。
在memcache.c文件main函数中，通过调用memcached_thread_init函数来初始化工作线程
```
void memcached_thread_init(int nthreads, struct event_base *main_base) {
    int         i;
    int         power;
    /* 对多线程中使用到的锁和条件变量初始化  */
    for (i = 0; i < POWER_LARGEST; i++) {
        pthread_mutex_init(&lru_locks[i], NULL);//lru链表锁
    }
    pthread_mutex_init(&worker_hang_lock, NULL);//可以让工作线程挂起

    pthread_mutex_init(&init_lock, NULL);//工作线程初始化锁
    pthread_cond_init(&init_cond, NULL);//初始化条件变量，用于主线程等待子线程完成初始化

    pthread_mutex_init(&cqi_freelist_lock, NULL);//消息队列锁
    cqi_freelist = NULL;//这个为消息队列

    /* 用于控制哈希表锁 */
    if (nthreads < 3) {
        power = 10;
    } else if (nthreads < 4) {
        power = 11;
    } else if (nthreads < 5) {
        power = 12;
    } else {
        /* 8192 buckets, and central locks don't scale much past 5 threads */
        power = 13;
    }

    if (power >= hashpower) {
        fprintf(stderr, "Hash table power size (%d) cannot be equal to or less than item lock table (%d)\n", hashpower, power);
        fprintf(stderr, "Item lock table grows with `-t N` (worker threadcount)\n");
        fprintf(stderr, "Hash table grows with `-o hashpower=N` \n");
        exit(1);
    }

    item_lock_count = hashsize(power);
    item_lock_hashpower = power;
   //为哈希表分配锁数组空间
    item_locks = calloc(item_lock_count, sizeof(pthread_mutex_t));
    if (! item_locks) {
        perror("Can't allocate item locks");
        exit(1);
    }
    for (i = 0; i < item_lock_count; i++) {
        pthread_mutex_init(&item_locks[i], NULL);
    }
    //给工作线程分配空间，并初始化
    threads = calloc(nthreads, sizeof(LIBEVENT_THREAD));
    if (! threads) {
        perror("Can't allocate thread descriptors");
        exit(1);
    }

    dispatcher_thread.base = main_base;
    dispatcher_thread.thread_id = pthread_self();

    for (i = 0; i < nthreads; i++) {
        int fds[2];
        if (pipe(fds)) {
            perror("Can't create notify pipe");
            exit(1);
        }
        //主线程和子线程通信用的管道
        threads[i].notify_receive_fd = fds[0];
        threads[i].notify_send_fd = fds[1];

        setup_thread(&threads[i]);//建立线程，即为初始化子线程的libevent,并监听管道的
      // 读端，初始化子线程的消息队列等待
        /* Reserve three fds for the libevent base, and two for the pipe */
        stats.reserved_fds += 5;
    }

    /* Create threads after we've done all the libevent setup. */
    for (i = 0; i < nthreads; i++) {
        create_worker(worker_libevent, &threads[i]);//开启子线程执行
    }

    /* 下面中间那个函数作用是等待子线程初始化完毕 */
    pthread_mutex_lock(&init_lock);
    wait_for_thread_registration(nthreads);
    pthread_mutex_unlock(&init_lock);
}
```
这个函数主要是完成n个子线程的初始化以及开启执行。其中setup_thread函数完成线程结构体LIBEVENT_THREAD成员初始化，
1. 首先将给子线程分配一个libevent实例，然后将notify_receive_fd加入这个libevent的可读事件。
2. 接着为了这个子线程的消息队列分配内存，并初始化。
3. 最后为这个子线程创建后缀缓存，暂时还不知道这缓存的用处。

create_worker函数用于开启子线程，第一个参数为回调函数，第二个参数为回调函数的参数。回调函数即线程执行函数。在这个回调函数worker_libevent又调用了register_thread_initialized这个函数，注册这个子线程。最后调用libevent的event_base_loop函数开启子线程的事件循环。
```
static void setup_thread(LIBEVENT_THREAD *me) {
    me->base = event_init();//分配一个libevent实例
    if (! me->base) {
        fprintf(stderr, "Can't allocate event base\n");
        exit(1);
    }

    /* Listen for notifications from other threads */
    event_set(&me->notify_event, me->notify_receive_fd,
              EV_READ | EV_PERSIST, thread_libevent_process, me);
    event_base_set(me->base, &me->notify_event);
    //将管道添加libevent事件循环中
    if (event_add(&me->notify_event, 0) == -1) {
        fprintf(stderr, "Can't monitor libevent notify pipe\n");
        exit(1);
    }
    //给消息队列分配内存
    me->new_conn_queue = malloc(sizeof(struct conn_queue));
    if (me->new_conn_queue == NULL) {
        perror("Failed to allocate memory for connection queue");
        exit(EXIT_FAILURE);
    }
    //初始化消息队列，将head和tail初始化为NULL
    cq_init(me->new_conn_queue);

    if (pthread_mutex_init(&me->stats.mutex, NULL) != 0) {
        perror("Failed to initialize mutex");
        exit(EXIT_FAILURE);
    }
   //分配缓存
    me->suffix_cache = cache_create("suffix", SUFFIX_SIZE, sizeof(char*),
                                    NULL, NULL);
    if (me->suffix_cache == NULL) {
        fprintf(stderr, "Failed to create suffix cache\n");
        exit(EXIT_FAILURE);
    }
}
/*++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
static void create_worker(void *(*func)(void *), void *arg) {
    pthread_t       thread;
    pthread_attr_t  attr;
    int             ret;

    pthread_attr_init(&attr);
    //开启子线程执行，子线程函数为回调函数func
    if ((ret = pthread_create(&thread, &attr, func, arg)) != 0) {
        fprintf(stderr, "Can't create thread: %s\n",
                strerror(ret));
        exit(1);
    }
}
/*++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*/
static void *worker_libevent(void *arg) {
    LIBEVENT_THREAD *me = arg;

    /* Any per-thread setup can happen here; memcached_thread_init() will block until
     * all threads have finished initializing.
     */

    register_thread_initialized();
    //开启事件循环
    event_base_loop(me->base, 0);
    return NULL;
}
```

# 困扰我的一个问题

----

在看线程这部分源码的过程中，有一个地方困惑了我好久。先来看下源码，涉及以下两个函数：
```
memcached_thread_init函数最后三行：
    pthread_mutex_lock(&init_lock);
    wait_for_thread_registration(nthreads);
    pthread_mutex_unlock(&init_lock);
/* ++++++++++++++++++++++++++++++++++++++++++++++++++ */
static void wait_for_thread_registration(int nthreads) {
    while (init_count < nthreads) {
        pthread_cond_wait(&init_cond, &init_lock);
    }
}
/* +++++++++++++++++++++++++++++++++++++++++++++++++++ */
static void register_thread_initialized(void) {
    pthread_mutex_lock(&init_lock);
    init_count++;
    pthread_cond_signal(&init_cond);
    pthread_mutex_unlock(&init_lock);
    /* Force worker threads to pile up if someone wants us to */
    pthread_mutex_lock(&worker_hang_lock);
    pthread_mutex_unlock(&worker_hang_lock);
}
```
在memcached_thread_init函数中调用wait_for_thread_registration等待所有的子线程建立完毕。我之前的困惑是，因为主线程有调用pthread_mutex_lock(&init_lock)然后睡眠在wait_for_thread_registration函数里面的pthread_cond_wait中。如果主线执行更快，而且占有init_lock这把锁，那么在执行redister_thread_initialized函数中，没有一个子线程可以获取init_lock了，这样的话，主线程在等待init_count的值增长到5，子线程在等待被主线程占有的init_lock，那么程序就卡死，无法继续往下执行了。

后来，我查阅资料，发现是我不了解pthread_cond_wait这个函数。pthread_cond_wait函数在调用时，会先将锁给释放了，然后才投入睡眠；当收到pthread_cond_signal发送的消息时，这时线程从pthread_cond_wait总被唤醒，并且重新获取锁。这样就可以解释之前的问题了。主线程调用pthread_cond_wait投入睡眠，释放锁，然后子线程在redister_thread_initialized中获得锁，将init_count值+1，接着调用pthread_cond_signal唤醒主线程，主线程重新获得锁，再判断init_count<nthreads，这样的好处是除了在子线程保护init_count操作原子性，在主线程在判断init_count时，也是原子的。

到此为止，子线程就建立完毕，此时，子线程都已经处于libevent的事件循环当中，而且只有管道的可读一个事件。接下来，主线调用网络模块，监听套接字，最后主线程的libevent实例也处于事件循环中，此时的套接字有服务器端监听的TCP和域套接字，UDP套接字已经分配给子线程负责了，因为udp无需建立连接。接来看来一个客户端达到之后，是如何传递给子线程，子线程是如何接收的。

# 主线程给子线程传递套接字

----

要查看主线程是如何给子线程传递套接字，只需要找到tcp套接字的回调函数；查看子线程是如何接收套接字，只需要查看管道的读端的回调函数即可。

当服务器到达一个客户端，服务器端调用dispatch_conn_new函数来将客户端的套接字分配给子线程：
```
void dispatch_conn_new(int sfd, enum conn_states init_state, int event_flags,
                       int read_buffer_size, enum network_transport transport) {
    CQ_ITEM *item = cqi_new();//新建一个消息实例
    char buf[1];
    if (item == NULL) {
        close(sfd);
        /* given that malloc failed this may also fail, but let's try */
        fprintf(stderr, "Failed to allocate memory for connection object\n");
        return ;
    }
    //选择子线程
    int tid = (last_thread + 1) % settings.num_threads;

    LIBEVENT_THREAD *thread = threads + tid;

    last_thread = tid;
    //初始化消息实例
    item->sfd = sfd;
    item->init_state = init_state;
    item->event_flags = event_flags;
    item->read_buffer_size = read_buffer_size;
    item->transport = transport;
    //将消息实例插入选择的子线程的消息队列中
    cq_push(thread->new_conn_queue, item);

    MEMCACHED_CONN_DISPATCH(sfd, thread->thread_id);
    buf[0] = 'c';
    //给这个子线程发送一个字符，激活管道可读事件。
    if (write(thread->notify_send_fd, buf, 1) != 1) {
        perror("Writing to thread notify pipe");
    }
}
```
memcache的消息是预先分配的，默认先分配64个CQ_ITEM消息实例，这样可以避免较多的内存碎片产生。所以CQ\_ITEM *item = cqi_new()如果是第一次调用，则先分配64个CQ_ITEM实例，然后返回第一个；之后再次调用这个函数时，则是直接从预先分配的CQ_ITEM链表中获取。

子线程的选择是采用轮询的方式，每次选择的线程总是上次选择线程的下一个线程。

# 子线程接收套接字

----

子线程接收父进程的套接字，管道的可读事件的回调函数为thread_libevent_process:
```
static void thread_libevent_process(int fd, short which, void *arg) {
    LIBEVENT_THREAD *me = arg;
    CQ_ITEM *item;
    char buf[1];

    if (read(fd, buf, 1) != 1)
        if (settings.verbose > 0)
            fprintf(stderr, "Can't read from libevent pipe\n");

    switch (buf[0]) {
    case 'c':
    item = cq_pop(me->new_conn_queue);

    if (NULL != item) {
        conn *c = conn_new(item->sfd, item->init_state, item->event_flags,
                           item->read_buffer_size, item->transport, me->base);
        if (c == NULL) {
            if (IS_UDP(item->transport)) {
                fprintf(stderr, "Can't listen for events on UDP socket\n");
                exit(1);
            } else {
                if (settings.verbose > 0) {
                    fprintf(stderr, "Can't listen for events on fd %d\n",
                        item->sfd);
                }
                close(item->sfd);
            }
        } else {
            c->thread = me;//这个'c'出现的很诡异
        }
        cqi_free(item);
    }
        break;
    /* we were told to pause and report in */
    case 'p':
    register_thread_initialized();
        break;
    }
}
```
这个函数简单地将消息从消息队列取出，并且调用conn_new函数，获取一个conn实例，这个实例主要是用于存储客户端发来的消息以及存储发往客户端的消息。conn_new函数还将这个客户端的fd添加进这个子线程的Libevent事件循环中。

接下来就是等待客户端发送命令，处理业务。这部分很复杂，涉及memcache状态机，下篇文章在好好分析。。。





























