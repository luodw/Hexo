title: NSQ源码分析之概述
date: 2016-12-08 15:03:29
tags:
- nsq
categories:
- nsq

toc: true

---


消息队列在互联网公司使用非常普遍，因此也促使我去学习研究消息队列的原理以及细节问题；之前也有接触过消息队列，最主要就是在异步处理方面，当然消息队列还解耦，流量削峰等功能；目前消息队列产品也比较多，例如kafka，ActiveMQ，RabbitMQ，NSQ等等；之前原本打算看kafka，但是处于学习成本(kafka是scala编写，之前scala接触的比较少)，所以就先不看kafka，选择了NSQ；NSQ主要是golang编写，本人刚好非常喜欢golang这门语言，因此在学习NSQ的同时，也可以学习NSQ是如何优雅地使用golang;

![厦门飞机场](http://7xjnip.com1.z0.glb.clouddn.com/ldw-1802933924.jpg "")

目前，看了nsqlookupd的代码，写的真的很精美，我觉得代码可以和redis相媲美，这等后续分析代码时再详说；关于NSQ的特性，可以查看[NSQ官网](http://nsq.io/overview/features_and_guarantees.html "")；这篇文章主要分析以下几点:
1. NSQ概述;
2. python操作NSQ;
3. 总结;

【版权声明】博客内容由罗道文的私房菜拥有版权，允许转载，但请标明原文链接[http://luodw.cc/2016/12/08/nsq01/#more](http://luodw.cc/2016/12/08/nsq01/#more "")

# NSQ概述

---

NSQ提供了三大组件以及一些工具，三大组件为:
1. nqsd NSQ主要组件，用于存储消息以及分发消息；
2. nsqlookupd 用于管理nsqd集群拓扑，提供查询nsqd主机地址的服务以及服务最终一致性；
3. nsqadmin 用于管理以及查看集群中的topic,channel,node等等；

对于单机版，只需要用到nsqd就够了，但是单机会出现单点问题以及没有监控，因此如果是线上环境，都会部署nsqlookupd,nsqadmin以及nsqd集群；这里先给出我手绘的NSQ拓扑图:
![NSQ拓扑](http://7xjnip.com1.z0.glb.clouddn.com/ldw-3139862022.jpg "")

NSQ的拓扑结构和文件系统的拓扑结构类似，有一个中心节点来管理集群节点；我们从图中可以看出: 
1. nsqlookupd服务同时开启tcp和http两个监听服务，nsqd会作为客户端，连上nsqlookupd的tcp服务，并上报自己的topic和channel信息，以及通过心跳机制判断nsqd状态；还有个http服务提供给nsqadmin获取集群信息；
2. nsqadmin只开启http服务，其实就是一个web服务，提供给客户端查询集群信息；
3. nsqd也会同时开启tcp和http服务，两个服务都可以提供给生产者和消费者，http服务还提供给nsqadmin获取该nsqd本地topic和channel信息；

以上就是NSQ集群服务整体拓扑信息，下面来看下客户端方面；NSQ提供了多种语言的支持，比如go-nsq for golang，pynsq for python等；上述拓扑信息，我也是看了pynsq才弄懂了客户端是如何和nsq集群连接的；我们来看下: 
1. 生产者会同时连上NSQ集群中所有nsqd节点，当然这些节点的地址是在Writer初始化时，通过外界传递进去；当发布消息时，writer会随机选择一个nsqd节点发布某个topic的消息；
2. 消费者也会同时连上NSQ集群中所有nsqd节点，reader首先会连上nsqlookupd，获取集群中topic的所有producer，然后通过tcp连上所有producer节点，并在本地用tornado轮询每个连接，当某个连接有可读事件时，即有消息达到，处理即可；

根据我自己的理解，说说NSQ优点:
* 高可用(无单点问题) writer和reader是直接连上各个nsqd节点，因此即使nsqlookupd挂了，也不影响线上正常使用；即使某个nsqd节点挂了，writer发布消息时，发现节点挂了，可以选择其他节点(当然，这是客户端负责的)，单个节点挂了对reader无影响；
* 高性能 writer在发布消息时，是随机发布到集群中nsqd节点，因此在一定程序上达到负载均衡；reader同时监听着集群中所有nsqd节点，无论哪个节点有消息，都会投递到reader上；
* 高可扩展 当向集群中添加节点时，首先reader会通过nsqlookupd发现新的节点加入，并i自动连接；因为writer连接的nsqd节点的地址是初始化时设置的，因此增加节点时，只需要在初始化writer时，添加新节点的地址即可；

ok，分析了NSQ集群整体的拓扑结构之后，我们来看下单个nsqd节点是如何处理消息的，下面给出官网提供的动图:
![nsqd消息处理](https://f.cloud.github.com/assets/187441/1700696/f1434dc8-6029-11e3-8a66-18ca4ea10aca.gif "")

当向某个topic发布一个消息时，该消息会被复制到所有的channel，如果channel只有一个客户端，那么channel就将消息投递给这个客户端；如果channel的客户端不止一个，那么channel将把消息随机投递给任何一个客户端，这也可以看做是客户端的负载均衡；

# python操作nsq

----

NSQ官网上已经有NSQ快速入门操作，这里就不去讲述了，我们来看下python是如何操作nsq；首先要下载pynsq包，可以用
```bash
pip3 install pynsq
```
然后需要在三个终端分别开启nsqd，nsqlookupd和nsqadmin服务
```bash
./nsqlookupd
./nsqd --lookupd-tcp-address=127.0.0.1:4160
./nsqadmin --lookupd-http-address=127.0.0.1:4161
```

三个服务开启之后，我们就可以编写生产者和消费者；生产者代码如下：
```python
import nsq
import tornado.ioloop
import time

def pub_message():
    writer.pub('test', time.strftime('%H:%M:%S').encode('utf-8'), finish_pub)

def finish_pub(conn, data):
    print(data)

writer = nsq.Writer(['127.0.0.1:4150'])
tornado.ioloop.PeriodicCallback(pub_message, 5000).start()
nsq.run()
```
消费者代码如下：
```python
import nsq

def handler(message):
    print(message.body)
    return True

r = nsq.Reader(message_handler=handler,
        nsqd_tcp_addresses=['127.0.0.1:4150'],
        topic='test', channel='test', lookupd_poll_interval=15)
nsq.run()
```
这里消费者，暂时连接到具体的nsqd实例，因为连接到nsqlookupd会报错，根据出错提示，应该是pynsq包对nsqlookupd返回的结果处理出错；

这里的生产者每隔5秒向'test' topic发送时间字符串，消费者可以得到这个时间字符串，我们可以看下上述生产者和消费的输出；
```
//生产者输出，返回ok，表示消息投递成功
charles@charles-Aspire-4741:~/mydir/pydir$ python3 nsq_producer.py 
b'OK'
b'OK'
b'OK'
b'OK'
.....
//消费者输出
charles@charles-Aspire-4741:~/mydir/pydir$ python3 nsq_consume.py 
b'19:36:11'
b'19:36:16'
b'19:36:21'
b'19:36:26'
b'19:36:31'
.....
```
上述就是python操作nsq最简单的示例程序；
 
## 总结

-----

这篇文章分析了nsq的架构设计，并通过一个简单的例子说明了nsq如何使用；当然nsq还有很多配置参数，例如每隔消息队列的长度，以及内存使用上限等等；后续文章，将继续分析nsqlookupd和nsqd的源码。




















