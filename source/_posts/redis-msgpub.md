title: redis源码分析之广播订阅机制
date: 2016-02-15 11:05:26
tags:
- redis
categories:
- redis

---

# redis消息队列之发布/订阅

这篇文章分析下redis发布/订阅。这种模式的特点就是有一个客户端向某个频道channel发布消息msg，N个订阅了这个频道的客户端都会接收到消息msg，有点类似广播的感觉。下面先用实例展示pub/sub是如何使用，最后在分析源码是如何实现的。

# redis使用订阅/发布

首先开启一个客户端，然后订阅到test频道:
```
127.0.0.1:6379> subscribe test
Reading messages... (press Ctrl-C to quit)
1) "subscribe"//订阅操作
2) "test"//订阅频道名称
3) (integer) 1//订阅频道唯一标识
```
然后在另一个客户端，向这个频道发布一条消息:
```
127.0.0.1:6379> publish test "hello world!"
(integer) 1
```
这时之前订阅test频道的客户端将会收到这条消息：
```
127.0.0.1:6379> subscribe test
Reading messages... (press Ctrl-C to quit)
1) "subscribe"
2) "test"
3) (integer) 1
1) "message"//表明这条是消息
2) "test"//消息来自的频道
3) "hello world!"//消息内容
```
以上就是订阅与发布的使用示例，还有两个命令是可以订阅和退订带有通配符的频道名称，即psubscribe和punsubscribe,官网介绍psubscribe命令时，支持下面三种匹配：
* h?llo subscribes to hello, hallo and hxllo
* h*llo subscribes to hllo and heeeello
* h[ae]llo subscribes to hello and hallo, but not hillo

# 发布/订阅源码实现

这个发布和订阅实现很简单，因为并不需要将数据插入到数据库中，只需要操作服务器和客户端的两个属性即可。

我们先来看下服务器和客户端相关属性介绍：
```
struct redisServer {
  .......
  /* Pubsub */
  dict *pubsub_channels;  /* 映射频道和订阅频道的客户端链表 */
  list *pubsub_patterns;  /* 订阅模式列表，为pubsubPattern结构 */
  .......
}
typedef struct redisClient {
  .....
  dict *pubsub_channels;  /* 这个客户端感兴趣的频道列表,值为NULL */
  list *pubsub_patterns;  /* 这个客户端感兴趣的频道模式，为字符串对象*/
  ........
}redisClient;

typedef struct pubsubPattern {
    redisClient *client;
    robj *pattern;
} pubsubPattern;/* 服务器和客户端中的链表存储的数据类型 */
```
当客户端调用subscribe订阅一个频道时，就往server的pubsub_channels相关的频道所对应的链表添加这个客户端。并往redisClient的pubsub_channels添加这个频道信息。当一个客户端publish一个频道一条信息后，会到server查找订阅这个频道所对应的客户端链表，并将消息发送给这些客户端。

先来看下subscribe源码分析:
```
/* pubsub.c */
void subscribeCommand(redisClient *c) {
    int j;
    //subscribe channel1 channel2 ,,,，所以c->argv[]从第二个参数开始存储频道名称
    for (j = 1; j < c->argc; j++)
        pubsubSubscribeChannel(c,c->argv[j]);//调用订阅函数
    c->flags |= REDIS_PUBSUB;
}

//++++++++++++++++++++++++++++++++++++++++++++++++
int pubsubSubscribeChannel(redisClient *c, robj *channel) {
    dictEntry *de;
    list *clients = NULL;
    int retval = 0;

    /* 将频道添加进客户端的channel->clients_list字典中*/
    if (dictAdd(c->pubsub_channels,channel,NULL) == DICT_OK) {
        retval = 1;
        incrRefCount(channel);
        /* 在server查找这个频道的客户端链表是否存在 */
        de = dictFind(server.pubsub_channels,channel);
        if (de == NULL) {//如果不存在，则新建一个
            clients = listCreate();
            dictAdd(server.pubsub_channels,channel,clients);//添加进字典中
            incrRefCount(channel);
        } else {
            clients = dictGetVal(de);//如果已存在，则直接获取频道所对应的客户端链表
        }
        listAddNodeTail(clients,c);//将客户端添加进客户端链表中
    }
    /* 初始化客户端信息 */
    addReply(c,shared.mbulkhdr[3]);//输出"*3\r\n"
    addReply(c,shared.subscribebulk);//输出“$9\r\nsubscribe\r\n”
    addReplyBulk(c,channel);//将频道名称封装成"$4\r\ntest\r\n"形式
    addReplyLongLong(c,clientSubscriptionsCount(c));//输出客户端订阅个数，也就是频道序号
    return retval;
}
```
这样这个客户端就订阅了test这个频道，而且这时的客户端由于订阅了某一个频道，则调用read阻塞等待服务器给他发送频道信息。接下来就看下publish这个命令的执行函数:
```
void publishCommand(redisClient *c) {
    //c->argv[1]为频道的名称，c->argv[2]为消息对象。下面函数就是将消息发送给所有订阅频道的客户端
    int receivers = pubsubPublishMessage(c->argv[1],c->argv[2]);
    if (server.cluster_enabled)
        clusterPropagatePublish(c->argv[1],c->argv[2]);
    else
        forceCommandPropagation(c,REDIS_PROPAGATE_REPL);
    addReplyLongLong(c,receivers);//给调用publish命令的客户端发送订阅c->argv[1]频道的客户端数
}
```
我们来看下pubsubPublishMessage函数是如何将消息发送给客户端的：
```
/* Publish a message */
int pubsubPublishMessage(robj *channel, robj *message) {
    int receivers = 0;
    dictEntry *de;
    listNode *ln;
    listIter li;

    /* 发送消息给订阅频道的客户端 */
    de = dictFind(server.pubsub_channels,channel);
    if (de) {
        list *list = dictGetVal(de);//获得客户端链表
        listNode *ln;
        listIter li;

        listRewind(list,&li);//迭代器初始化
        while ((ln = listNext(&li)) != NULL) {//迭代链表的每一个客户端
            redisClient *c = ln->value;
            //发送消息
            addReply(c,shared.mbulkhdr[3]);//输出"*3\r\n"
            addReply(c,shared.messagebulk);//输出"$7\r\nmessage\r\n"
            addReplyBulk(c,channel);//输出"$4\r\ntest\r\n"格式
            addReplyBulk(c,message);//输出"$5\r\nhello\r\n"
            receivers++;
        }
    }
```
这个函数先取出server.pubsub_channels字典中，订阅这个频道的客户端链表，然后将消息发送给每一个客户端即可。

当调用unscubscribe退订频道时，只是简单将频道从客户端c->pubsub_channels删除，以及将客户端从server.pubsub_channels频道所对应的链表中删除即可。

redis还支持订阅模式匹配的的多个频道，用psubscribe订阅和punsubscribe退订。本质上和订阅一个明确的频道没什么差别，只是最后在publish发送消息给客户端时，除了要发给明确的频道外，还需将消息发送给模式匹配的所有客户端。
