title: redis源码分析之命令处理过程
date: 2016-02-05 10:55:46
tags:
- redis
categories:
- redis

---
# 命令执行过程

这篇文章分析下客户端连接redis服务器，并且输入命令之后，redis服务器做了什么。这里以最基础的set命令为例。

# 客户端连接服务器

要分析客户端是如何连接服务器，即客户端调用connect之后，服务器做了啥，首先就是看下监听listenfd可读事件(listenfd永远为可读事件，等有客户端connect之后，此时产生可读事件)的回调函数acceptTcpHandler
```
//networking.c
/* ------------------------------------------------------------------------- */
void acceptTcpHandler(aeEventLoop *el, int fd, void *privdata, int mask) {
    int cport, cfd, max = MAX_ACCEPTS_PER_CALL;
    char cip[REDIS_IP_STR_LEN];
    REDIS_NOTUSED(el);
    REDIS_NOTUSED(mask);
    REDIS_NOTUSED(privdata);

    while(max--) {
        cfd = anetTcpAccept(server.neterr, fd, cip, sizeof(cip), &cport);
        if (cfd == ANET_ERR) {
            if (errno != EWOULDBLOCK)
                redisLog(REDIS_WARNING,
                    "Accepting client connection: %s", server.neterr);
            return;
        }
        redisLog(REDIS_VERBOSE,"Accepted %s:%d", cip, cport);
        acceptCommonHandler(cfd,0);
    }
}
```
常量MAX_ACCEPTS_PER_CALL=1000，所以对于listenfd一次可读事件，可以接收最多1000个客户端。这个回调函数先调用anetTcpAccept函数，accept客户端socket，接着把accept接收的客户端cfd传递给函数acceptCommonHandler处理
```
static void acceptCommonHandler(int fd, int flags) {
    redisClient *c;
    if ((c = createClient(fd)) == NULL) {
        redisLog(REDIS_WARNING,
            "Error registering fd event for the new client: %s (fd=%d)",
            strerror(errno),fd);
        close(fd); /* May be already closed, just ignore errors */
        return;
    }
    if (listLength(server.clients) > server.maxclients) {
        char *err = "-ERR max number of clients reached\r\n";

        /* That's a best effort error message, don't check write errors */
        if (write(c->fd,err,strlen(err)) == -1) {
            /* Nothing to do, Just to avoid the warning... */
        }
        server.stat_rejected_conn++;
        freeClient(c);
        return;
    }
    server.stat_numconnections++;
    c->flags |= flags;
}
```
这个函数先是调用createClient创建一个redisClient，每一个客户端fd对应一个redisClient，用于存储读取的操作命令以及缓存输出的结果。然后就是判断客户端数量是否超出事先定义的个数，如果是则向客户端回复一个错误信息，并且回收这个redisClient。接下来主要看下创建redisClient函数
```
redisClient *createClient(int fd) {
    redisClient *c = zmalloc(sizeof(redisClient));

    /* passing -1 as fd it is possible to create a non connected client.
     * This is useful since all the Redis commands needs to be executed
     * in the context of a client. When commands are executed in other
     * contexts (for instance a Lua script) we need a non connected client. */
    if (fd != -1) {
        anetNonBlock(NULL,fd);
        anetEnableTcpNoDelay(NULL,fd);
        if (server.tcpkeepalive)
            anetKeepAlive(NULL,fd,server.tcpkeepalive);
        if (aeCreateFileEvent(server.el,fd,AE_READABLE,
            readQueryFromClient, c) == AE_ERR)
        {
            close(fd);
            zfree(c);
            return NULL;
        }
    }

    selectDb(c,0);//初始化为0数据库，默认16个
    c->id = server.next_client_id++;
    c->fd = fd;
    /* 省略初始化redisClient各个属性部分 */
    if (fd != -1) listAddNodeTail(server.clients,c);//加入server.clients客户端链表末尾
    initClientMultiState(c);//初始化事物机制属性
    return c;
}
```
注释中也有说明当fd==-1时，可用于lua 脚本执行脚本。如果不是-1，则说明是客户端连接，这时设置为非阻塞，允许Nagle算法，TCP默认是禁止的。如果需要，开启keepalive设置。接着在这个fd上创建可读事件，等待客户端发送命令。以上就是redis客户端连接的过程。

# 服务器执行命令过程

当客户端连上服务器之后，接下来，就会向服务器发送执行命令。这时，就要从客户端fd的回调函数readQueryFromClient开始分析:
```
void readQueryFromClient(aeEventLoop *el, int fd, void *privdata, int mask) {
    redisClient *c = (redisClient*) privdata;
    int nread, readlen;
    size_t qblen;
    server.current_client = c;
    readlen = REDIS_IOBUF_LEN;
    qblen = sdslen(c->querybuf);
    if (c->querybuf_peak < qblen) c->querybuf_peak = qblen;
    //为查询缓冲区分配内存空间
    c->querybuf = sdsMakeRoomFor(c->querybuf, readlen);
    /* 读取客户端发送的命令  */
    nread = read(fd, c->querybuf+qblen, readlen);

    /* 省略...... */
    processInputBuffer(c);//处理输入的命令字符串，
}
```
redis命令有分为单结果回复和多结果回复，例如get命令，就是获取一个键的value,即为单回复；lrange命令就是获取列表某一范围的元素，即为多结果回复。具体参考[redis官网](http://www.redis.cn/topics/protocol.html "")。这里说下最简单的set mykey myvalue命令格式，这个命令会被转化为如下单引号字符串:
```
"*3\r\n$3\r\nSET\r\n$5\r\nmykey\r\n$7\r\nmyvalue\r\n"
```
这个是二进制安全的命令字符串格式，每个参数之前都有这个参数的字节数，这样及时碰到'\0'，也会按普通字符处理。在processInputBuffer函数中调用processMultibulkBuffer。redis还支持旧式命令字符串格式，这些字符串格式只有空格作为分隔符，所以如果碰到'\0'，字符串会提前终止，是二进制不安全的，在processInputBuffer中调用processInlineBuffer处理。通常在客户端为telnet时产生不安全的二进制字符串，可以在redis-cli和telnet分别分发送ping命令，并用tcpdump查看字节数即可知道。
1. 当使用telnet客户端，输入命令为ping时，tcpdump输出如下:
```
18:21:39.609411 IP localhost.37721 > localhost.6379: Flags [P.], seq 2174951300:2174951306, ack 1980339778, win 342, options [nop,nop,TS val 7060488 ecr 7050263], length 6
```
发出的字符串长度为6，说明字符串格式为"ping\r\n";
2. 当使用redis自带客户端，即redis-cli时，tcpdump输出如下:
```
18:26:17.986651 IP localhost.37728 > localhost.6379: Flags [P.], seq 26:40, ack 41, win 342, options [nop,nop,TS val 7130083 ecr 7129312], length 14
```
这时发出的字符串长度为14，此时的字符串格式为"*1\r\n$4\r\nping\r\n"

在processInputBuffer函数中调用processMultibulkBuffer，将c->querybuf中的命令二进制字符串分解为字符串数组，并保存在redisClient属性中，例如
```
"*3\r\n$3\r\nSET\r\n$5\r\nmykey\r\n$7\r\nmyvalue\r\n"
分割成字符数组保存在redisCLient数组中:
c->argv[0]="set",c->argv[1]="mykey",c->argv[2]="myvalue"
c->argc=3
```

接下来就调用processCommand(c)来处理这个命令，在这个函数中，分别讨论了很多中情况，例如是否集群模式。是否为事务执行等等，最关键的一行是
```
call(c,REDIS_CALL_FULL);
```
在call函数中，分别讨论了不同情况，我们也是找到最关键的一行代码:
```
c->cmd->proc(c);
```
这行代码调用了当前执行命令的命令执行函数，对于set命令为setCommand函数,而set命令也有几种，例如set \[nx\]\[xx\]\[ex <seconds>\]\[px<milliseconds>\],在这里，我们先关注最简单的set key value格式，在setCommand函数中调用setGenericCommand,在后者函数内部，调用
```
setKey(c->db,key,val);
addReply(c, ok_reply ? ok_reply : shared.ok);
```
setkey函数先查找db中是否有含有key的键值对，如果没有，则添加，如果有，则覆盖。最后调用addReply回复客户端。

# 回复客户端

当有需要返回给客户端时，调用addReply函数，在该函数中，先调用prepareClientToWrite函数给fd注册一个写事件，然后将回复字符串写进redisCLient输出缓存c->buf
```
int prepareClientToWrite(redisClient *c) {
    /*  ......    */
    if (aeCreateFileEvent(server.el, c->fd, AE_WRITABLE,
                sendReplyToClient, c) == AE_ERR)
        {
            freeClientAsync(c);
            return REDIS_ERR;
        }
```
这样在下一次事件循环中，即可通知c->fd可写事件，调用可写事件的回调函数sendReplyToClient，在该回调函数中，最要几行代码如下
```
/* .............  */
nwritten = write(fd,c->buf+c->sentlen,c->bufpos-c->sentlen);
/* ..............  */
  if (c->bufpos == 0 && listLength(c->reply) == 0) {
        c->sentlen = 0;
        aeDeleteFileEvent(server.el,c->fd,AE_WRITABLE);

        /* Close connection after entire reply has been sent. */
        if (c->flags & REDIS_CLOSE_AFTER_REPLY) freeClient(c);
    }
```
先是调用系统调用write将输出缓冲区的数据返回给客户端，最后再将这个客户端的写事件删除，因为以无数据可写，但是读事件还在，等待客户端下一次输入命令。

到这里，一次命令执行就结束了，这里只是介绍简单的set命令，不同的命令执行函数不同，但是大部分命令执行流程都是一样的。
