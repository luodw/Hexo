title: redis消息队列之链表实现
date: 2016-02-13 11:03:45
tags:
- redis
categories:
- redis

---
# redis消息队列之链表实现

之前在知乎上看到用redis来实现消息队列，其实消息队列，linux在进程间通信有提到过，以及在memcache主线程和工作线程之间通信也是通过消息队列，但是我认为redis消息队列有一个好处，就是可以实现分布式和共享，就和memcache作为mysql的缓存和mysql自带的缓存一样。

redis有两种方式实现消息队列
1. 用redis自带的链表数据结构
2. 用redis发布/订阅模式


# 链表实现消息队列

redis链表支持前后插入以及前后取出，所以如果往尾部插入元素，往头部取出元素，这就是一种消息队列，也可以说是消费者/生产者模型。可以利用lpush和rpop来实现。但是有一个问题，如果链表中没有数据，那么消费者将要在while循环中调用rpop，这样以来就浪费cpu资源，好在redis提供一种阻塞版pop命令brpop或者blpop，用法为brpop/blpop list timeout, 当链表为空的时候，brpop/blpop将阻塞，直到设置超时时间到或者list插入一个元素。看下用法如下:
```
charles@charles-Aspire-4741:~/mydir/mylib/redis$ ./src/redis-cli
127.0.0.1:6379> lpush list hello
(integer) 1
127.0.0.1:6379> brpop list 0
1) "list"
2) "hello"
127.0.0.1:6379> brpop list 0
//阻塞在这里
/* ---------------------------------------------------- */
//当我在另一个客户端lpush一个元素之后，客户端输出为
127.0.0.1:6379> brpop list 0
1) "list"
2) "world"
(50.60s)//阻塞的时间
```
当链表为空的时候，brpop是阻塞的，等待超时时间到或者另一个客户端lpush一个元素。接下来，看下源码是如何实现阻塞brpop命令的。要实现客户端阻塞，只需要服务器不给客户端发送消息，那么客户端就会阻塞在read调用中，等待消息到达。这是很好实现的，关键是如何判断这个客户端阻塞的链表有数据到达以及通知客户端解除阻塞？redis的做法是，将阻塞的键以及阻塞在这个键上的客户端链表存储在一个字典中，然后每当向数据库插入一个链表时，就判断这个新插入的链表是否有客户端阻塞，有的话，就解除这个阻塞的客户端，并且发送刚插入链表元素给客户端，客户端就这样解除阻塞。

先看下有关数据结构，以及server和client有关属性
```
//阻塞状态
typedef struct blockingState {
    /* Generic fields. */
    mstime_t timeout;       /* 超时时间 */

    /* REDIS_BLOCK_LIST */
    dict *keys;             /* The keys we are waiting to terminate a blocking
                             * operation such as BLPOP. Otherwise NULL. */
    robj *target;           /* The key that should receive the element,
                             * for BRPOPLPUSH. */

    /* REDIS_BLOCK_WAIT */
    int numreplicas;        /* Number of replicas we are waiting for ACK. */
    long long reploffset;   /* Replication offset to reach. */
} blockingState;
//继续列表
typedef struct readyList {
    redisDb *db;//就绪键所在的数据库
    robj *key;//就绪键
} readyList;
//客户端有关属性
typedef struct redisClient {
   int btype;              /* Type of blocking op if REDIS_BLOCKED. */
    blockingState bpop;     /* blocking state */
}
//服务器有关属性
struct redisServer {
     /* Blocked clients */
    unsigned int bpop_blocked_clients; /* Number of clients blocked by lists */
    list *unblocked_clients; /* list of clients to unblock before next loop */
    list *ready_keys;        /* List of readyList structures for BLPOP & co */
}
//数据库有关属性
typedef struct redisDb {
       //keys->redisCLient映射
       dict *blocking_keys;        /* Keys with clients waiting for data (BLPOP) */
    dict *ready_keys;           /* Blocked keys that received a PUSH */
}redisDB
```
必须对上述的数据结构足够了解，否则很难看懂下面的代码，因为这些代码需要操作上述的数据结构。先从brpop命令执行函数开始分析，brpop命令执行函数为
```
void brpopCommand(redisClient *c) {
    blockingPopGenericCommand(c,REDIS_TAIL);
}
//++++++++++++++++++++++++++++++++++++++++++++++++++
void blockingPopGenericCommand(redisClient *c, int where) {
    robj *o;
    mstime_t timeout;
    int j;

    if (getTimeoutFromObjectOrReply(c,c->argv[c->argc-1],&timeout,UNIT_SECONDS)
        != REDIS_OK) return;//将超时时间保存在timeout中

    for (j = 1; j < c->argc-1; j++) {
        o = lookupKeyWrite(c->db,c->argv[j]);//在数据库中查找操作的链表
        if (o != NULL) {//如果不为空
            if (o->type != REDIS_LIST) {//不是链表类型
                addReply(c,shared.wrongtypeerr);//报错
                return;
            } else {
                if (listTypeLength(o) != 0) {//链表不为空
                    /* Non empty list, this is like a non normal [LR]POP. */
                    char *event = (where == REDIS_HEAD) ? "lpop" : "rpop";
                    robj *value = listTypePop(o,where);//从链表中pop出一个元素
                    redisAssert(value != NULL);
                    //给客户端发送pop出来的元素信息
                    addReplyMultiBulkLen(c,2);
                    addReplyBulk(c,c->argv[j]);
                    addReplyBulk(c,value);
                    decrRefCount(value);
                    notifyKeyspaceEvent(REDIS_NOTIFY_LIST,event,
                                        c->argv[j],c->db->id);
                    if (listTypeLength(o) == 0) {//如果链表为空，从数据库删除链表
                        dbDelete(c->db,c->argv[j]);
                        notifyKeyspaceEvent(REDIS_NOTIFY_GENERIC,"del",
                                            c->argv[j],c->db->id);
                    }
                 /* 省略一部分 */
               }
          }
       }
    }
     /* 如果链表为空，则阻塞客户端 */
        blockForKeys(c, c->argv + 1, c->argc - 2, timeout, NULL);
}
```
从源码可以看出，brpop可以操作多个链表变量，例如brpop list1 list2 0，但是只能输出第一个有元素的链表。如果list1没有元素，而list2有元素，则输出list2的元素；如果两个都有元素，则输出list1的元素；如果都没有元素，则等待其中某个链表插入一个元素，之后在2返回。最后调用blockForyKeys阻塞
```
void blockForKeys(redisClient *c, robj **keys, int numkeys, mstime_t timeout, robj *target) {
    dictEntry *de;
    list *l;
    int j;

    c->bpop.timeout = timeout;//超时时间赋值给客户端blockingState属性
    c->bpop.target = target;//这属性适用于brpoplpush命令的输入对象，如果是brpop,    //则target为空

    if (target != NULL) incrRefCount(target);//不为空，增加引用计数

    for (j = 0; j < numkeys; j++) {
        /* 将阻塞的key存入c.bpop.keys字典中 */
        if (dictAdd(c->bpop.keys,keys[j],NULL) != DICT_OK) continue;
        incrRefCount(keys[j]);

        /* And in the other "side", to map keys -> clients */
        //将阻塞的key和客户端添加进c->db->blocking_keys
        de = dictFind(c->db->blocking_keys,keys[j]);
        if (de == NULL) {
            int retval;

            /* For every key we take a list of clients blocked for it */
            l = listCreate();
            retval = dictAdd(c->db->blocking_keys,keys[j],l);
            incrRefCount(keys[j]);
            redisAssertWithInfo(c,keys[j],retval == DICT_OK);
        } else {
            l = dictGetVal(de);
        }
        listAddNodeTail(l,c);//添加到阻塞键的客户点链表中
    }
    blockClient(c,REDIS_BLOCKED_LIST);//设置客户端阻塞标志
}
```
blockClient函数只是简单的设置客户端属性，如下
```
void blockClient(redisClient *c, int btype) {
    c->flags |= REDIS_BLOCKED;//设置标志
    c->btype = btype;//阻塞操作类型
    server.bpop_blocked_clients++;
}
```
由于这个函数之后，brpop命令执行函数就结束了，由于没有给客户端发送消息，所以客户端就阻塞在read调用中。那么如何解开客户端的阻塞了？

# 插入一个元素解阻塞

任何指令的执行函数都是在processCommand函数中调用call函数，然后在call函数中调用命令执行函数，lpush也一样。当执行完lpush之后，此时链表不为空，回到processCommand调用中，执行以下语句
```
  if (listLength(server.ready_keys))
            handleClientsBlockedOnLists();
```
这两行代码是先检查server.ready_keys是否为空，如果不为空，说明已经有一些就绪的链表，此时可以判断是否有客户端阻塞在这个键值上，如果有，则唤醒；现在问题又来了，这个server.ready_keys在哪更新链表了？

原来是在dbAdd函数中，当往数据库中添加的值类型为REDIS-LIST时，这时就要调用signalListAsReady函数将链表指针添加进server.ready_keys:
```
//db.c
void dbAdd(redisDb *db, robj *key, robj *val) {
    sds copy = sdsdup(key->ptr);
    int retval = dictAdd(db->dict, copy, val);//将数据添加进数据库

    redisAssertWithInfo(NULL,key,retval == REDIS_OK);
    //判断是否为链表类型，如果是，调用有链表已经ready函数
    if (val->type == REDIS_LIST) signalListAsReady(db, key);
    if (server.cluster_enabled) slotToKeyAdd(key);
 }
//t_list.c
void signalListAsReady(redisDb *db, robj *key) {
    readyList *rl;

    /* 没有客户端阻塞在这个键上，则直接返回. */
    if (dictFind(db->blocking_keys,key) == NULL) return;

    /* 这个键已近被唤醒了，所以没必要重新入队 */
    if (dictFind(db->ready_keys,key) != NULL) return;

    /* Ok, 除了上述两情况，把这个键放入server.ready_keys */
    rl = zmalloc(sizeof(*rl));
    rl->key = key;
    rl->db = db;
    incrRefCount(key);
    listAddNodeTail(server.ready_keys,rl);//添加链表末尾

    /* We also add the key in the db->ready_keys dictionary in order
     * to avoid adding it multiple times into a list with a simple O(1)
     * check. */
    incrRefCount(key);
    //同时将这个阻塞键放入db->ready_keys
    redisAssert(dictAdd(db->ready_keys,key,NULL) == DICT_OK);
}
```
OK，这时server.ready_keys上已经有就绪键了，这时就调用processCommand函数中的handleClientsBlockedOnLists()函数来处理阻塞客户端,在这个函数中，
```
void handleClientsBlockedOnLists(void) {
    while(listLength(server.ready_keys) != 0) {
        list *l;
        /* 将server.ready_keys赋给一个新的list,再将server.ready_keys清空  */
        l = server.ready_keys;
        server.ready_keys = listCreate();
        /* 迭代每一个就绪的每一个readyList  */
        while(listLength(l) != 0) {
            listNode *ln = listFirst(l);//获取第一个就绪readyList
            readyList *rl = ln->value;

            /* 从rl所属的数据库中删除rl */
            dictDelete(rl->db->ready_keys,rl->key);

            /* 查询rl所属的数据库查找rl->key ,给阻塞客户端回复rl->key链表中的第一个元素*/
            robj *o = lookupKeyWrite(rl->db,rl->key);
            if (o != NULL && o->type == REDIS_LIST) {
                dictEntry *de;

                /* 在rl->db->blocking_keys查找阻塞在rl->key的客户端链表 */
                de = dictFind(rl->db->blocking_keys,rl->key);
                if (de) {
                    list *clients = dictGetVal(de);//转换为客户端链表
                    int numclients = listLength(clients);

                    while(numclients--) {//给每个客户端发送消息
                        listNode *clientnode = listFirst(clients);
                        redisClient *receiver = clientnode->value;//阻塞的客户端
                        robj *dstkey = receiver->bpop.target;//brpoplpush命令目的链表
                        int where = (receiver->lastcmd &&
                                     receiver->lastcmd->proc == blpopCommand) ?
                                    REDIS_HEAD : REDIS_TAIL;//获取取出的方向
                        robj *value = listTypePop(o,where);//取出就绪链表的元素

                        if (value) {
                            /* Protect receiver->bpop.target, that will be
                             * freed by the next unblockClient()
                             * call. */
                            if (dstkey) incrRefCount(dstkey);
                            unblockClient(receiver);//设置客户端为非阻塞状态

                            if (serveClientBlockedOnList(receiver,
                                rl->key,dstkey,rl->db,value,
                                where) == REDIS_ERR)
                            {
                                /* If we failed serving the client we need
                                 * to also undo the POP operation. */
                                    listTypePush(o,value,where);
                            }//给客户端回复链表中的元素内容

                            if (dstkey) decrRefCount(dstkey);
                            decrRefCount(value);
                        } else {
                            break;
                        }
                    }
                }
                //如果链表为空，则从数据库中删除
                if (listTypeLength(o) == 0) dbDelete(rl->db,rl->key);
                /* We don't call signalModifiedKey() as it was already called
                 * when an element was pushed on the list. */
            }

            /* 回收rl */
            decrRefCount(rl->key);
            zfree(rl);
            listDelNode(l,ln);
        }
        listRelease(l); /* We have the new list on place at this point. */
    }
}
```
从这个源码可知，如果有两个客户端，同时阻塞在一个链表上面，那么如果链表插入一个元素之后，只有先阻塞的那个客户端收到消息，后面阻塞的那个客户端继续阻塞，这也是先阻塞先服务的思想。handleClientsBlockedOnLists函数调用了unblockClient(receiver)，该函数功能为接触客户端阻塞标志，以及找到db阻塞在key上的客户端链表，并将接触阻塞的客户端从链表删除。然后调用serveClientBlockOnList给客户端回复刚在链表插入的元素。
```
int serveClientBlockedOnList(redisClient *receiver, robj *key, robj *dstkey, redisDb *db, robj *value, int where)
{
    robj *argv[3];

    if (dstkey == NULL) {
        /* Propagate the [LR]POP operation. */
        argv[0] = (where == REDIS_HEAD) ? shared.lpop :
                                          shared.rpop;
        argv[1] = key;
        propagate((where == REDIS_HEAD) ?
            server.lpopCommand : server.rpopCommand,
            db->id,argv,2,REDIS_PROPAGATE_AOF|REDIS_PROPAGATE_REPL);

        /* BRPOP/BLPOP */
        addReplyMultiBulkLen(receiver,2);
        addReplyBulk(receiver,key);
        addReplyBulk(receiver,value);
    } else {
        /* BRPOPLPUSH */
          /* 省略  */
    }
}
```
propagate函数主要是将命令信息发送给aof和slave。函数中省略部分是brpoplpush list list1 0命令的目的链表list1非空时，将从list链表pop出来的元素插入list1中。当给客户端发送消息之后，客户端就从read函数调用中返回，变为不阻塞。

# 通过超时时间解阻塞

如果链表一直没有数据插入，那么客户端将会一直阻塞下去，这肯定是不行的，所以brpop还支持超时阻塞，即阻塞时间超过一定值之后，服务器返回一个空值，这样客户端就解脱阻塞了。

对于时间超时，都放在了100ms执行一次的时间事件中；超时解脱阻塞函数也在serverCron中；在serverCron->clientsCron->clientsCronHandleTimeout
```
int clientsCronHandleTimeout(redisClient *c, mstime_t now_ms) {
    time_t now = now_ms/1000;
    //..........
    else if (c->flags & REDIS_BLOCKED) {
        /* Blocked OPS timeout is handled with milliseconds resolution.
         * However note that the actual resolution is limited by
         * server.hz. */

        if (c->bpop.timeout != 0 && c->bpop.timeout < now_ms) {
            /* Handle blocking operation specific timeout. */
            replyToBlockedClientTimedOut(c);
            unblockClient(c);
        }
    }
    //.............
```
把这个函数不相干的代码删除，主要部分先判断这个客户端是否阻塞，如果是，超时时间是否到期，如果是，则调用replyToBlockedClientTimedOut给客户端回复一个空回复，以及接触客户端阻塞。

链表消息队列实现暂时分析到这，下篇文章分析下订阅与发布。
