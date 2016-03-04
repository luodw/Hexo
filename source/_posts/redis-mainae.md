title: redis源码之Mainae模块
date: 2016-01-23 14:50:24
tags:
- redis
categories:
- redis
toc: true

---

redis源码是我研一下学期和暑假学习的，后来研二上学期又看了leveldb和memcache源码，感觉redis源码是最好阅读，结构很清晰，代码写得也很优美．再读memcache源码之前有想过读libevent的源码，但是仔细想想，redis自己也实现了事件驱动机制，所以我就不看libevent源码，在memcache源码分析之后，回过头来看下redis的事件驱动机制即可，因为我主要还是想看看实现原理．

所以想利用研二寒假总结下redis源码一些特色的东西，例如事件驱动模块，sentinel，cluster,订阅，慢查询等等，今天开篇就说说事件驱动机制Mainae模块．

# Mainae模块概要

----

Redis采用的是单进程单线程模型(开启aof时，创建子进程将数据刷新到磁盘)，一开始Mainae模块监听listenfd和域套接字，等待客户端的连接．当有一个客户端达到之后，接收这个客户端clientfd，为这个客户端添加可读事件，并将这个客户端加入事件驱动中；当客户端发送一条命令之后，这个clientfd产生可读事件，redis服务器调用这个clientfd的回调函数，处理命令请求，处理完请求之后，将回复给客户端的内容写进输出缓冲区，然后给这个clientfd注册一个可写事件，那么下一次事件通知时，将数据写回给客户端，再删除这个clientfd的可写事件，但是这个clientfd可读事件还是存在的，等待下一次客户端输入．

所以对于redis而言，Mainae模块是至关重要的，它直接掌控着redis的运行．Mainae模块和libevent一样，先写一个通用接口，然后底层用select,epoll,evport,kqueue分别实现了这个通用接口，在不同的系统调用适合的接口，linux下面优先使用epoll，所以这篇文章主要是分析epoll实现．

# Mainae一些定义

----

首先来看下，Mainae模块的一些结构体定义和函数指针定义，因为这些是接下去看源码的一些先决条件．
```
struct aeEventLoop;//先前声明，因为函数指针用到了
/* Types and data structures */
typedef void aeFileProc(struct aeEventLoop *eventLoop, int fd, void *clientData, int mask);//socket可写可读事件的回调函数指针类型
typedef int aeTimeProc(struct aeEventLoop *eventLoop, long long id, void *clientData);//时间事件回调函数指针类型
typedef void aeEventFinalizerProc(struct aeEventLoop *eventLoop, void *clientData);//事件消除函数指针类型
typedef void aeBeforeSleepProc(struct aeEventLoop *eventLoop);//在开始事件循环之前执行的函数指针类型

/* File event structure */
/* 文件事件结构体 */
typedef struct aeFileEvent {
    int mask; /* one of AE_(READABLE|WRITABLE) ,事件类型(可读可写)*/
    aeFileProc *rfileProc;//socket可读事件回调函数
    aeFileProc *wfileProc;//socket可写事件回调函数
    void *clientData;//客户端数据，即代表客户端的redisClient结构体
} aeFileEvent;

/* Time event structure */
/* 时间事件结构体 */
typedef struct aeTimeEvent {
    long long id; /* 这个时间事件编号. */
    long when_sec; /* 秒数 */
    long when_ms; /* 毫秒数 */
    aeTimeProc *timeProc;//时间事件回调函数
    aeEventFinalizerProc *finalizerProc;//时间事件销毁函数
    void *clientData;//客户端结构体
    struct aeTimeEvent *next;//指向下一个时间事件
} aeTimeEvent;

/* A fired event */
/* 激活的事件 */
typedef struct aeFiredEvent {
    int fd;//哪个fd上有事件
    int mask;//这个事件的类型
} aeFiredEvent;

/* State of an event based program */
/* Mainae的主体结构体　 */
typedef struct aeEventLoop {
    int maxfd;   /* 目前为止注册的最大文件描述符 */
    int setsize; /* 监听文件描述符的最大值 */
    long long timeEventNextId;//时间事件的下一个id
    time_t lastTime;     /* 检测系统时钟倾斜 */
    aeFileEvent *events; /* 注册的所有文件描述符事件 */
    aeFiredEvent *fired; /* 激活的事件 */
    aeTimeEvent *timeEventHead;//注册的所有时间事件
    int stop;//用于关闭这个Mainae事件循环
    void *apidata; /* 这是每种实现的具体数据，epoll是aeApiState结构体 */
    aeBeforeSleepProc *beforesleep;//进入事件循环前的函数指针
} aeEventLoop;
```
关于几个结构体，有几点需要说明，
1. 文件事件类型有AE_NONE,AE_READABLE,AE_WRTABLE三种以及后两者的或．
2. 激活事件结构体是作为epoll_event和aeFileEvent的中间桥梁，当epoll检测到事件之后，将产生事件的fd以及事件类型赋给aeFiredEvent，然后根据aeFiredEvent事件的fd，找到aeFileEvent结构，根据事件类型，调用相应的回调函数．
3. aeEventLoop结构体相当于libevent中的event_base，作为整个模块的中心结构体，掌管着所有事件．

# Mainae模块函数解析

----

## EventLoop创建函数

接下来主要看下Mainae提供的主要接口，首先是创建一个EventLoop事件循环:
```
ac.c
--------------------------------------------------------------------
millisecondsaeEventLoop *aeCreateEventLoop(int setsize) {
    aeEventLoop *eventLoop;
    int i;

    //为EventLoop分配内存空间
    if ((eventLoop = zmalloc(sizeof(*eventLoop))) == NULL) goto err;
　　//为事件分配内存空间
    eventLoop->events = zmalloc(sizeof(aeFileEvent)*setsize);
　　//为了激活事件分配内存空间
    eventLoop->fired = zmalloc(sizeof(aeFiredEvent)*setsize);
    if (eventLoop->events == NULL || eventLoop->fired == NULL) goto err;
    eventLoop->setsize = setsize;//默认值为10032,32是预留出来的
    eventLoop->lastTime = time(NULL);//获取目前时间
    eventLoop->timeEventHead = NULL;
    eventLoop->timeEventNextId = 0;
    eventLoop->stop = 0;
    eventLoop->maxfd = -1;
    eventLoop->beforesleep = NULL;
　　//调用底层函数，设置apidata
    if (aeApiCreate(eventLoop) == -1) goto err;
 　 //初始化每个事件的类型为AE_NONE
    for (i = 0; i < setsize; i++)
        eventLoop->events[i].mask = AE_NONE;
    return eventLoop;

ae_epoll.c
----------------------------
/* epoll这个实现的私有数据结构 */
typedef struct aeApiState {
    int epfd;//epoll_create返回的实例
    struct epoll_event *events;//epoll_wait返回激活的事件
} aeApiState;

static int aeApiCreate(aeEventLoop *eventLoop) {
    aeApiState *state = zmalloc(sizeof(aeApiState));//分配内存

    if (!state) return -1;
    //为存储激活事件预先分配内存
    state->events = zmalloc(sizeof(struct epoll_event)*eventLoop->setsize);
    if (!state->events) {
        zfree(state);
        return -1;
    }
　　//调用epoll_create创建一个epoll实例
    state->epfd = epoll_create(1024); /* 1024 is just a hint for the kernel */
    if (state->epfd == -1) {
        zfree(state->events);
        zfree(state);
        return -1;
    }
    eventLoop->apidata = state;//赋值
    return 0;
}
```
以上就创建好了一个EventLoop，包括为文件事件和时间事件预留了空间等等；创建好之后，接下来就是往里面添加事件和删除事件了．

## 添加事件

添加事件时，先将事件添加进epoll中，然后再初始化EventLoop中相应的文件事件结构体
```
ae.c
-----------------------------------------------------------------------
int aeCreateFileEvent(aeEventLoop *eventLoop, int fd, int mask,
        aeFileProc *proc, void *clientData)
{
    if (fd >= eventLoop->setsize) {//文件描述符超出最大值，报错返回
        errno = ERANGE;
        return AE_ERR;
    }
    aeFileEvent *fe = &eventLoop->events[fd];//获取EventLoop中fd对应的结构体

    if (aeApiAddEvent(eventLoop, fd, mask) == -1)//将fd添加进epoll中
        return AE_ERR;
    fe->mask |= mask;//设置文件类型
    if (mask & AE_READABLE) fe->rfileProc = proc;//设置回调函数
    if (mask & AE_WRITABLE) fe->wfileProc = proc;
    fe->clientData = clientData;//客户端数据
    if (fd > eventLoop->maxfd)
        eventLoop->maxfd = fd;//设置最大值
    return AE_OK;
}

ae_epoll.c
-----------------------------------------------------------------------
static int aeApiAddEvent(aeEventLoop *eventLoop, int fd, int mask) {
    aeApiState *state = eventLoop->apidata;//获取epoll私有数据
    struct epoll_event ee;//定义一个epoll事件
    /* 如果fd上的事件为AE_NONE，这时用add操作；如果fd上事件不为空，则
　　为mod修改操作 */
    int op = eventLoop->events[fd].mask == AE_NONE ?
            EPOLL_CTL_ADD : EPOLL_CTL_MOD;

    ee.events = 0;
    mask |= eventLoop->events[fd].mask; /* 合并原来的事件类型 */
    if (mask & AE_READABLE) ee.events |= EPOLLIN;//设置epoll事件类型
    if (mask & AE_WRITABLE) ee.events |= EPOLLOUT;
    ee.data.u64 = 0; /* avoid valgrind warning(我感觉是初始化后面四个字节为０)
    因为ee.data为union，占８字节,而fd4字节 */
    ee.data.fd = fd;
　　//添加进epoll事件中
    if (epoll_ctl(state->epfd,op,fd,&ee) == -1) return -1;
    return 0;
}
```
添加可读事件一般是在redis主程序初始化时，添加listenfd为可读事件，等待客户端连接；还有就是一个客户端连上之后，也注册一个可读事件，准备接收客户端发来的数据；当服务器处理好数据之后，需要回复客户端时，则注册一个可写事件；

## 删除事件

删除事件也是一样，先删除epoll事件，再删除EventLoop中对应的事件
```
ae.c
------------------------------------------------------------------------
void aeDeleteFileEvent(aeEventLoop *eventLoop, int fd, int mask)
{
    if (fd >= eventLoop->setsize) return;
    aeFileEvent *fe = &eventLoop->events[fd];//获取相应的事件类型
    if (fe->mask == AE_NONE) return;//这个fd没有监听事件类型，直接返回
　　
　　//删除epoll上fd事件类型
    aeApiDelEvent(eventLoop, fd, mask);
    fe->mask = fe->mask & (~mask);//关闭对应类型
    if (fd == eventLoop->maxfd && fe->mask == AE_NONE) {
        /* Update the max fd */
        int j;
　　　　//如果这个关闭的fd是最大值，且没有事件监听类型，则更新fd最大值
        for (j = eventLoop->maxfd-1; j >= 0; j--)
            if (eventLoop->events[j].mask != AE_NONE) break;
        eventLoop->maxfd = j;
    }
}

ae_epoll.c
-----------------------------------------------------------------------
static void aeApiDelEvent(aeEventLoop *eventLoop, int fd, int delmask) {
    aeApiState *state = eventLoop->apidata;
    struct epoll_event ee;
    int mask = eventLoop->events[fd].mask & (~delmask);//关闭事件类型

    ee.events = 0;
    if (mask & AE_READABLE) ee.events |= EPOLLIN;
    if (mask & AE_WRITABLE) ee.events |= EPOLLOUT;
    ee.data.u64 = 0; /* avoid valgrind warning */
    ee.data.fd = fd;
    if (mask != AE_NONE) {//如果这个fd上没有监听事件，则从epoll中删除
        epoll_ctl(state->epfd,EPOLL_CTL_MOD,fd,&ee);
    } else {//如果这个fd还有事件监听，则修改事件监听类型(删除delmask类型)
        /* Note, Kernel < 2.6.9 requires a non null event pointer even for
         * EPOLL_CTL_DEL. */
        epoll_ctl(state->epfd,EPOLL_CTL_DEL,fd,&ee);
    }
}
```
再redis中一般情况下有两种情况会删除事件
1. 一是服务器给客户端回复之后，因为后面没有数据可写，需要把可写事件删除；
2. 另一个是客户端关闭时，需要把这个fd的可读事件删除；

## 事件驱动

将事件添加进epoll事件之后，这时调用epoll_wait函数等待可读或可写事件发生，将激活的事件存储在epoll_wait函数的第二个参数中，接下来看下redis是如果是如何实现的．
```
ae.c
--------------------------------------------------------------------------
int aeProcessEvents(aeEventLoop *eventLoop, int flags)
{
    int processed = 0, numevents;
    /* 省略不必要代码  */
       //调用底层事件函数，返回激活事件的个数
       numevents = aeApiPoll(eventLoop, tvp);
        for (j = 0; j < numevents; j++) {
　　　　　　//获取激活事件
            aeFileEvent *fe = &eventLoop->events[eventLoop->fired[j].fd];
            int mask = eventLoop->fired[j].mask;//激活事件类型
            int fd = eventLoop->fired[j].fd;//激活事件描述符
            int rfired = 0;

	    /* note the fe->mask & mask & ... code: maybe an already processed
             * event removed an element that fired and we still didn't
             * processed, so we check if the event is still valid. */
            if (fe->mask & mask & AE_READABLE) {
                rfired = 1;//可读事件，调用相应回调函数
                fe->rfileProc(eventLoop,fd,fe->clientData,mask);
            }
            if (fe->mask & mask & AE_WRITABLE) {
　　　　　　//可写事件，调用相应回调函数
                if (!rfired || fe->wfileProc != fe->rfileProc)
                    fe->wfileProc(eventLoop,fd,fe->clientData,mask);
            }
            processed++;//处理个数加1．
        }
    }

ae_epoll.c
----------------------------------------------------------------------------
static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
    aeApiState *state = eventLoop->apidata;
    int retval, numevents = 0;
  
    //调用epoll_wait函数，激活事件存储在state->events数组中
    retval = epoll_wait(state->epfd,state->events,eventLoop->setsize,
            tvp ? (tvp->tv_sec*1000 + tvp->tv_usec/1000) : -1);
    if (retval > 0) {//如果有事件发生
        int j;

        numevents = retval;
        for (j = 0; j < numevents; j++) {
            int mask = 0;
            struct epoll_event *e = state->events+j;

            if (e->events & EPOLLIN) mask |= AE_READABLE;
            if (e->events & EPOLLOUT) mask |= AE_WRITABLE;
            if (e->events & EPOLLERR) mask |= AE_WRITABLE;
            if (e->events & EPOLLHUP) mask |= AE_WRITABLE;
　　　　　　//fired数组存储激活事件的fd和事件类型
            eventLoop->fired[j].fd = e->data.fd;
            eventLoop->fired[j].mask = mask;
        }
    }
    return numevents;//返回激活事件个数
}
```
Mainae事件驱动先是调用epoll_wait函数，返回激活的事件以及事件个数，然后设置eventLoop->fired数组，最后在aeProcessEvents函数迭代每个事件，并调用相应的回调函数．redis主程序其实就是这样在一个while循环中，调用aeProcessEvent,不断等待事件发生，不断处理．
```
void aeMain(aeEventLoop *eventLoop) {
    eventLoop->stop = 0;
    while (!eventLoop->stop) {
        if (eventLoop->beforesleep != NULL)
            eventLoop->beforesleep(eventLoop);
        aeProcessEvents(eventLoop, AE_ALL_EVENTS);
    }
}
```

## Mainae时间事件

在redis中，初始化服务器时，会定时处理一些业务，此时就需要设置定时事件．创建时间事件函数如下:
```
ae.c
--------------------------------------------------------------------
ong long aeCreateTimeEvent(aeEventLoop *eventLoop, long long milliseconds,
        aeTimeProc *proc, void *clientData,
        aeEventFinalizerProc *finalizerProc)
{
    long long id = eventLoop->timeEventNextId++;//时间事件id
    aeTimeEvent *te;

    te = zmalloc(sizeof(*te));//分配内存空间
    if (te == NULL) return AE_ERR;
    te->id = id;
　　//为这个时间事件设置时间，即离现在的时间
    aeAddMillisecondsToNow(milliseconds,&te->when_sec,&te->when_ms);
    te->timeProc = proc;
    te->finalizerProc = finalizerProc;
    te->clientData = clientData;
    te->next = eventLoop->timeEventHead;//插入eventLoop时间事件链表
    eventLoop->timeEventHead = te;
    return id;
}

------------------------------------------------------------------------
static void aeAddMillisecondsToNow(long long milliseconds, long *sec, long *ms) {
    long cur_sec, cur_ms, when_sec, when_ms;

    aeGetTime(&cur_sec, &cur_ms);//获取当前时间
    when_sec = cur_sec + milliseconds/1000;//离现在多少秒
    when_ms = cur_ms + milliseconds%1000;//离现在多少毫秒
    if (when_ms >= 1000) {
        when_sec ++;
        when_ms -= 1000;
    }//进位
    *sec = when_sec;
    *ms = when_ms;
}

-------------------------------------------------------------------------
static void aeGetTime(long *seconds, long *milliseconds)
{
    struct timeval tv;

    gettimeofday(&tv, NULL);
    *seconds = tv.tv_sec;
    *milliseconds = tv.tv_usec/1000;
}
```
创建时间事件，并插入时间事件链表中．Mainae模块，调用epoll_wait的阻塞时间为时间事件的最小值，这样当epoll_wait函数返回时，可以先处理文件描述符事件，再处理到期的时间事件．

在调用aeProcessEvents函数时，先获取最近的时间事件以及最短时间struct tvp，然后调用epoll_wait阻塞tvp秒．先看下获取最近的时间事件
```
static aeTimeEvent *aeSearchNearestTimer(aeEventLoop *eventLoop)
{
    //时间事件链表的第一个时间事件
    aeTimeEvent *te = eventLoop->timeEventHead;
    aeTimeEvent *nearest = NULL;

    while(te) {
        if (!nearest || te->when_sec < nearest->when_sec ||
                (te->when_sec == nearest->when_sec &&
                 te->when_ms < nearest->when_ms))
            nearest = te;
        te = te->next;
    }
    return nearest;
}
```
获取最近时间事件之后，先获得最近时间事件离现在的时间，再调用aeApiPoll获取文件描述符激活事件，最后调用processTimeEvents处理事件事件
```
static int processTimeEvents(aeEventLoop *eventLoop) {
    int processed = 0;
    aeTimeEvent *te;
    long long maxId;
    time_t now = time(NULL);
    if (now < eventLoop->lastTime) {
        te = eventLoop->timeEventHead;
        while(te) {
            te->when_sec = 0;
            te = te->next;
        }
    }//据说这个是为了检测系统时钟倾斜，但是一开始lastTime初始化为创建eventLoop
　　//的时间点，按理说第一次调用时，是不会比now小
    eventLoop->lastTime = now;//将上次处理时间事件的时间设为now．

    te = eventLoop->timeEventHead;
    maxId = eventLoop->timeEventNextId-1;
    while(te) {
        long now_sec, now_ms;
        long long id;

        if (te->id > maxId) {
            te = te->next;
            continue;
        }
        aeGetTime(&now_sec, &now_ms);
        //判断这个时间事件的到期时间在now之前，如果是，则调用相应的回调函数
        if (now_sec > te->when_sec ||
            (now_sec == te->when_sec && now_ms >= te->when_ms))
        {
            int retval;

            id = te->id;
            retval = te->timeProc(eventLoop, id, te->clientData);
            processed++;
            if (retval != AE_NOMORE) {//判断是否出错，如果没出错，则返回的是
            //这个时间事件的下一次到期时间
                aeAddMillisecondsToNow(retval,&te->when_sec,&te->when_ms);
            } else {//调用出错，则删除这个时间事件
                aeDeleteTimeEvent(eventLoop, id);
            }
            te = eventLoop->timeEventHead;//执行完一次时间事件之后，即从头再此次便利
　　　　//因为这时又有事件到期了
        } else {
            te = te->next;
        }
    }
    return processed;
}
```

到此，redis的Mainae模块就分析结束了．相对第一次看源码，这次明显看得块，可能是我对这种机制很熟悉，所以看得也快．

相对于memcache的多线程编程，redis单线程模型更简单，思路更清晰．

据说libevent代码量就1.5w行，而Mainae模块代码几乎除了select,evport,select三个底层实现之外，其他都在这了，代码量还是很少的，关键是代码很清晰，很优美，很好阅读．



















































