title: kafka源码分析之概述
date: 2017-04-24 20:10:32
tags:
- kafka
categories:
- kafka

toc: true

---

最近帮实验室写了一个Spark+kafka实时处理日志的监控系统案例，大概流程为：
1. 用户购物日志发送给Kafka；
2. Spark实时从Kafka接收购物日志，利用Spark Streaming实时处理，最后将结果发送给Kafka；
3. 用Flask构建一个web程序接收Kafka处理后的数据，用Flask-SocketIO实时将每秒的数据发送给客户端浏览器；
4. 浏览器利用socket.io.js实时接收web发送来的数据，利用highcharts.js展示出来。
这个案例很好的展示了利用Spark+Kafka实时处理数据的开发模式。Spark在实时处理和批量处理都有很高的性能，Kafka消息队列在异步解耦，冗余处理和削峰等方面有很高的性能。

Kafka在互联网各大公司都有很广泛的应用，主要在于Kakfa性能出众，又有很好的扩展性和稳定性。而之前看过NSQ消息队列，对消息队列的分布式架构都有一定的了解，所以想最近这段时间看看kafka源码，熟悉下Kafka的整体架构，以及学习Scala和Java是如何写基础组件的。

这篇文章先介绍下Kafka的整体架构，在通过一个简单的实例展示Python是如何操作Kafka消息队列，如下：
1. Kafka整体架构；
2. Python操作Kafka；
3. 总结；

【版权声明】博客内容由罗道文的私房菜拥有版权，允许转载，但请标明原文链接[http://luodw.cc/2017/04/24/kafka01/#more](http://luodw.cc/2017/04/24/kafka01/#more "")

# Kafka整体架构

----

Kafka相对于NSQ架构更加的复杂，但也提供更丰富的功能，下面根据我的理解列出二者的不同点:
1. NSQ消费者采用的是push模式，而Kafka消费者采用的是pull模式；
2. NSQ消息被消费之后，即被删除，而Kafka消费数据之后，并不删除数据，所以Kafka也可以看成是一个存储系统；
3. NSQ没提供消息副本功能，而Kafka提供分区多副本，当leader宕机之后，可以重新选组提供服务，具有高可用性；
4. NSQ各个nsqd之间不进行通信，而Kafka Server之间进行通信，毕竟要进行副本传输；
5. Kafka消费提供组的概念，不同组的消费者可以消费同一个topic下所有的数据；而对于同组消费者，各个消费者按某种算法一起消费同一个topic下不同分区的消息。虽然NSQ并没有挺供消费者组的概念，但是NSQ的channel则提供了相同的功能；不同的channel相当于不同消费者组，都能收到topic的所有消息，然后同一个channel所对应的所有消费者相当于Kafka同一个消费者组内的消费者。二者在这方面实现的功能是一样的。

因此，我把NSQ看成是轻量级的消息队列，如果不需要消息副本，不需要提供消息冗余，只是简单消息的投递和消费我觉得可以使用NSQ，毕竟轻量，部署简单，也更容易深入理解源码。当然，如果需要很好的消息可靠性或者其他Kakfa其他特性，还是推荐Kafka。

下面先介绍下Kafka当中的专业术语:
1. broker　一个Kafka集群有多个服务器，其中一台即称为一个broker；
2. Topic 我们可以把topic看成是消息的种类，我们发送的每条消息都属于某个topic；
3. Partition Partition是物理的概念，一个topic下面可以有多个Partition，这些Partition拥有等同的地位，主要是为了实现负载均衡；
4. Producer　复杂发布消息到Kafka Broker；
5. Consumer　向Kafka读取消息的客户端；
6. Consumer Group　消费者组，每个consumer都属于一个ConsumerGroup，我们可以指定组的名字，如果不指定，则属于默认的消费者组；

下面同过一个简单的图示说明Kafka的拓扑结构以及与Producer和Consumer的关系
![Kafka简单的架构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-kafka.JPG "")

这里展示的是只是一个zookeeper（当然可以有多个）以及一个消费者组中的一个消费者（当然可以有多个消费者组和多个消费者），主要是为了简化分析。每个Kafka Server在启动时，都需要向zookeeper注册broker信息，路径为/brokers，可以通过zookeeper的ls /命令查看。等三个Kafka Server都启动之后，Producer与Consumer就可以连接投递和消费消息。这里假设有一个Topic，三个分区，每个分区只有一个副本，刚好对应图中的三个broker。对于多副本，等后续分析Kafka Server时再分析。

1. Producer向某个topic发送消息时，需要先连接上与这个topic相关的一台或者多台broker，因为broker之间会相互通信，最后通过一台broker，就可以找到所有与该topic相关的broker。当Producer在发布消息时，根据消息提供的key进行分区（最简单的方式就是哈稀求余），因此一条消息并将属于一个分区；如果分区函数设计得当，所有消息将会被均衡的发送到所有分区，实现负载均衡。在早期版本的Producer，有同步和异步的方式，而在最新的版本中只提供异步的方式，即将所有消息先存入一个队列，然后开启一个后台线不断从队列读取消息并发送给Kafka Sever。　
2. Consumer消费消息时，需要先连接zookeeper获取与topic相关的broker，然后再连接；等Consumer连上Kafka Server之后，然后发送FetchRequest请求，带上topic,partition和offset从相应的分区读取消息；

下面通过官网提供的图，简单说明下消费者组模式
![Kafka消费者组](http://7xjnip.com1.z0.glb.clouddn.com/ldw-consumer-groups.png "")

如图，假设有一个topic，四个partition；两个Kafka Server，每个Kafka Server分别有两个分区；有两个消费者组A和B。由图可知，ConsumerGroup A和ConsumerGroup B都可以消费同一个topic下的所有消息，而同一个消费者组内的消费者则消费topic下的不同分区；例如，ConsumerGroup A的C1消费分区0和3，而C2消费分区1和2。ConsumerGroup B下的四个Consumer则分别消费一个分区。

> 消费者组主要是为了实现同一个topic下的消息的消息实现不同的处理，例如同一个topic下的消息，即可用于hadoop进行批处理，也可以用于Spark流计算，还可以直接进行持久化到磁盘等等。

> 消费者组内的多个消费者主要就是为了实现负载均衡。　

# Ｐython操作Kafka

-----

这里用Python操作Kafka作为演示，只需要几行代码就可以实现生产者和消费者。生产者代码如下:
```python
# coding: utf-8
import time
from kafka import KafkaProducer

producer = KafkaProducer(bootstrap_servers='localhost:9092')
while True:
    producer.send('test', "Hello World!".encode('utf8'))
    time.sleep(3)
```

然后消费者代码如下:
```python
# coding: utf-8
from kafka import KafkaConsumer

consumer = KafkaConsumer('test')
for msg in consumer:
    print((msg.value).decode('utf8'))
```

我的测试环境只有一台Zookeeper和一台Kafka，生产者每隔3秒向test这个topic发送消息，消息内容为"Hello World!"。而消费者不断消费test的消息，PyCharm在consumer控制台下可以看到如下输出
```
/home/charles/Envs/env1/bin/python /home/charles/PycharmProjects/kafka/consumer.py
Hello World!
Hello World!
Hello World!
Hello World!
Hello World!
...
```

当然Kafka的Producer和Consumer都有很多配置，例如ack，是否自动commmitOffset等等，这也是我后续想看源码的原因，因为看了源码，可以更好的理解这些参数是什么意思，怎么做优化。

# 总结

----

这篇文章简单的介绍了下Kafka，也算对Kafka有个较为深入的认识，也为后续深入看源码打下基础。Kafka代码量好多，需要耐心慢慢啃，我有大概看了下Kafka的代码，有很多优秀的设计可以学习，包括NIO，Selector，Java并发包等等。先到这吧。