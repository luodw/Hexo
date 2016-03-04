title: redis源码分析之慢日志
date: 2016-02-14 11:01:19
tags:
- redis
categories:
- redis

---

# redis慢查询日志

在mysql中，有一类日志，叫慢查询日志，主要是保存查询时间超过一定阈值的sql语句，用于分析如何优化查询。redis也有一个慢查询日志，功能类似，存储查询时间超过事先定义的阈值的命令，用来分析和优化查询。

redis有两个和慢查询日志相关的选项：
* slowlog-log-slower-than 选项指定执行时间超过多少微秒（1 秒等于 1,000,000 微秒）的命令请求会被记录到日志上。举个例子， 如果这个选项的值为 100 ， 那么执行时间超过 100 微秒的命令就会被记录到慢查询日志； 如果这个选项的值为 500 ， 那么执行时间超过 500 微秒的命令就会被记录到慢查询日志； 诸如此类。
* slowlog-max-len 选项指定服务器最多保存多少条慢查询日志。服务器使用先进先出的方式保存多条慢查询日志： 当服务器储存的慢查询日志数量等于 slowlog-max-len 选项的值时， 服务器在添加一条新的慢查询日志之前， 会先将最旧的一条慢查询日志删除。举个例子， 如果服务器 slowlog-max-len 的值为 100 ， 并且假设服务器已经储存了 100 条慢查询日志， 那么如果服务器打算添加一条新日志的话， 它就必须先删除目前保存的最旧的那条日志， 然后再添加新日志。

我们先来看下慢查询日志是如何使用的，可以通过redis.conf配置文件配置上述两项，或者采用config set命令来设置
```
127.0.0.1:6379> slowlog get
(empty list or set)
127.0.0.1:6379> config get slowlog-log-slower-than
1) "slowlog-log-slower-than"
2) "1"
127.0.0.1:6379> config set slowlog-log-slower-than 2
OK
127.0.0.1:6379> config get slowlog-log-slower-than
1) "slowlog-log-slower-than"
2) "2"
127.0.0.1:6379> set name hello
OK
```
一开始慢日志为空，然后通过config get先获取变量slowlog-log-slower-than的值，为我之前设置的1，单位为微秒。然后通过命令config set命令设置为2微秒，然后执行一个set命令，我们来看下慢查询日志
```
127.0.0.1:6379> slowlog get
1) 1) (integer) 0//日志的唯一标识符
   2) (integer) 1454593637//命令执行时的unix时间戳
   3) (integer) 14//命令执行的时长，以微秒计算
   4) 1) "set" //命令以及命令参数
      2) "name"
      3) "hello"
```
其实之前的config命令，也会在慢日志中，我没列出。可以看下慢查询日志格式。慢查询日志还有一个选项是最多保留慢查询日志的条数slowlog-max-len，如果慢查询日志数量超出设定的阈值，则最旧的日志会被删除。

# 慢查询源码分析

解析来看下慢查询日志源码是如何实现的。慢查询日志数据结构为
```
//slowlog.h
typedef struct slowlogEntry {
    robj **argv;        /* 命令参数对象数组 */
    int argc;
    long long id;       /* Unique entry identifier. */
    long long duration; /* Time spent by the query, in nanoseconds. */
    time_t time;        /* Unix time at which the query was executed. */
} slowlogEntry;
```
这里注释的命令执行时间为纳秒，但是官网上是微秒，而且我觉得微秒更可信点，在server结构中，也有几个属性与慢日志相关
```
struct redisServer {
    //..................
    list *slowlog;                  /* SLOWLOG list of commands */
    long long slowlog_entry_id;     /* SLOWLOG current entry ID */
    long long slowlog_log_slower_than; /* SLOWLOG time limit (to get logged) */
    unsigned long slowlog_max_len;     /* SLOWLOG max number of items logged */
    //......................
}
```
redis用一个链表来存储所有的慢查询日志，在redis.c/main函数中的initServer函数中，调用slowlogInit函数初始化慢查询日志:
```
void slowlogInit(void) {
    server.slowlog = listCreate();//创建链表
    server.slowlog_entry_id = 0;//初始化日志id
    listSetFreeMethod(server.slowlog,slowlogFreeEntry);//注册日志析构函数，主要
//为了回收argv中存储的参数对象
}
```
初始化好慢查询日志之后，接下来在哪进行慢查询日志插入了？因为慢查询日志是需要知道命令的执行时间，所以肯定必须在命令执行之后，根据这个思路，我们在call函数中找到了慢查询日志插入点。
```
void call(redisClient *c, int flags) {
    /* ..... */
       start = ustime();
       c->cmd->proc(c);
       duration = ustime()-start;
    /* ......*/
       slowlogPushEntryIfNeeded(c->argv,c->argc,duration);
```
所以，这个命令时长是调用命令的执行函数所持续的时间，最后调用slowlog.c中的slowlogPushEntryIfNeeded函数如果有必要插入。
```
void slowlogPushEntryIfNeeded(robj **argv, int argc, long long duration) {
    if (server.slowlog_log_slower_than < 0) return; /* Slowlog disabled */
    if (duration >= server.slowlog_log_slower_than)
        listAddNodeHead(server.slowlog,slowlogCreateEntry(argv,argc,duration));

    /* 如果慢查询日志链表已满，则删除最旧的日志 */
    while (listLength(server.slowlog) > server.slowlog_max_len)
        listDelNode(server.slowlog,listLast(server.slowlog));
}
```
必须先创建好一个日志项，然后再将日志项插入慢日志列表头:
```
slowlogEntry *slowlogCreateEntry(robj **argv, int argc, long long duration) {
    slowlogEntry *se = zmalloc(sizeof(*se));
    int j, slargc = argc;
    //判断参数是否过多
    if (slargc > SLOWLOG_ENTRY_MAX_ARGC) slargc = SLOWLOG_ENTRY_MAX_ARGC;
    se->argc = slargc;
    se->argv = zmalloc(sizeof(robj*)*slargc);
    for (j = 0; j < slargc; j++) {
        if (slargc != argc && j == slargc-1) {
            se->argv[j] = createObject(REDIS_STRING,
                sdscatprintf(sdsempty(),"... (%d more arguments)",
                argc-slargc+1));//在最后一个参数输出提示
        } else {
            /* 有些字符串太长，进行缩减 */
            if (argv[j]->type == REDIS_STRING &&
                sdsEncodedObject(argv[j]) &&
                sdslen(argv[j]->ptr) > SLOWLOG_ENTRY_MAX_STRING)
            {
                sds s = sdsnewlen(argv[j]->ptr, SLOWLOG_ENTRY_MAX_STRING);

                s = sdscatprintf(s,"... (%lu more bytes)",
                    (unsigned long)
                    sdslen(argv[j]->ptr) - SLOWLOG_ENTRY_MAX_STRING);
                se->argv[j] = createObject(REDIS_STRING,s);
            } else {
                se->argv[j] = argv[j];
                incrRefCount(argv[j]);
            }
        }
    }
    //为slowlogEntry其他选项赋值
    se->time = time(NULL);
    se->duration = duration;
    se->id = server.slowlog_entry_id++;
    return se;
}
```

最后再来看下slowlog命令执行函数
```
void slowlogCommand(redisClient *c) {
    if (c->argc == 2 && !strcasecmp(c->argv[1]->ptr,"reset")) {
        slowlogReset();
        addReply(c,shared.ok);
    } else if (c->argc == 2 && !strcasecmp(c->argv[1]->ptr,"len")) {
        addReplyLongLong(c,listLength(server.slowlog));
    } else if ((c->argc == 2 || c->argc == 3) &&
               !strcasecmp(c->argv[1]->ptr,"get"))
    {
        long count = 10, sent = 0;
        listIter li;
        void *totentries;
        listNode *ln;
        slowlogEntry *se;

        if (c->argc == 3 &&
            getLongFromObjectOrReply(c,c->argv[2],&count,NULL) != REDIS_OK)
            return;

        listRewind(server.slowlog,&li);
        totentries = addDeferredMultiBulkLength(c);
        while(count-- && (ln = listNext(&li))) {
            int j;

            se = ln->value;
            addReplyMultiBulkLen(c,4);
            addReplyLongLong(c,se->id);
            addReplyLongLong(c,se->time);
            addReplyLongLong(c,se->duration);
            addReplyMultiBulkLen(c,se->argc);
            for (j = 0; j < se->argc; j++)
                addReplyBulk(c,se->argv[j]);
            sent++;
        }
        setDeferredMultiBulkLength(c,totentries,sent);
    } else {
        addReplyError(c,
            "Unknown SLOWLOG subcommand or wrong # of args. Try GET, RESET, LEN.");
    }
}
```
slowlog命令有三个子命令，
1. 第一个是reset,这时调用slowlogReset函数恢复日志列表，即删除所有日志:
```
void slowlogReset(void) {
    while (listLength(server.slowlog) > 0)
        listDelNode(server.slowlog,listLast(server.slowlog));
}
```
2. 第二个是len，返回日志链表长度
```
else if (c->argc == 2 && !strcasecmp(c->argv[1]->ptr,"len")) {
        addReplyLongLong(c,listLength(server.slowlog));
```
3. 第三个是get，返回的是所有慢日志,很简单，只是简单的迭代slowlog链表，输出每一个日志项。

慢查询日志整体相对较简单，在每次执行命令时，判断执行时间是否超时，如果超时，就插入慢查询日志链表中，之后就可以调用slowlog命令查询.
