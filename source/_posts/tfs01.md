title: TFS之DataServer启动执行过程
date: 2016-05-20 20:20:01
tags:
---
最近在实习,接触了tfs文件系统,刚好之前有决定往数据存储方向发展,因此很认真的看了tfs安装部署,以及源码.不得不说,tfs源码真心不是很容易看懂的,因为用了C++很多继承多态,回调机制,地处底层封装等等,我也是花了大概好几天天的时间才把DataServer整体部分看懂了;因此必须写篇博客记录下...


# 文件系统

---------------

学过计算机的朋友 ，都有听说过文件系统，简要地说，文件系统就是操作系统组织磁盘文件的一种方式，因为磁盘就是一个物理设备，只知道存储二进制的比特位，但是并不知道存储的是文件还是目录，因此操作系统要规划好如何将文件存入磁盘以及如何从磁盘取文件等等，这就是文件系统做的事；关于文件系统的介绍，《linux鸟哥的私房菜》前几章有很好的介绍。

当然对于linux来说，一切都是文件，因为在linux下面，文件系统的概念更广，有传统的基于磁盘的ext4,ext3...，有基于网络的sockfs，有基于内存的pipefs和procfs等等。通过一层虚拟文件系统vfs，屏蔽各个文件系统的差异，为用户提供统一的访问接口open,write,read,close等等；

分布式文件系统是属于用户态的文件系统，最终利用的还是操作系统内核的文件系统的存储功能；tfs将磁盘分成若干个块（其实就是大文件），一个块一般较大，可以存储较多的小文件；tfs就是将小文件存储在某个块中，也是从块中取小文件；我的理解就是操作系统文件系统单个文件为单位存储单个文件的数据，而分布式文件系统以块为单位存储各个小文件的数据。常见的分布式文件系统有GFS,HDFS,GridFS,TFS,FastFS等等；

# TFS简要概述

-----------------

最近两个星期都在看TFS文件系统dataserver部分源码，感受最深的就是快吐了，由于是C++写的，代码里面充斥太多的继承多态，回调，以及各种底层封装，反正就是一个字“乱”，也可能正如林老湿所说，“是时候换个姿势了”。经过我的坚持和林老湿的指导，最终还是把整个dataserver的执行过程看懂了，因此今天写篇博客总结下。

TFS（Taobao !FileSystem）是一个高可扩展、高可用、高性能、面向互联网服务的分布式文件系统，主要针对海量的非结构化数据，它构筑在普通的Linux机器集群上，关于tfs的介绍可以看[官方文档]("http://code.taobao.org/p/tfs/wiki/intro/" "")

先给出TFS整体框架图![TFS整体框架](http://7xjnip.com1.z0.glb.clouddn.com/ldw-tfs01.png "")
正如图所示，NameServer负责管理各个block和dataserver之间的对应关系，并不存储实际数据，而DataServer用于存储具体的数据，当应用程序要存储一个文件时，
1. 首先在客户端根据文件名解析出文件该文件所对应的block_id和file_id，接着访问NameServer，NameServer向客户端返回这个block_id对应块所在的dataserver地址链表（有一个是primary_ds,其他为了冗余存储），
2. 客户端接着访问primary_ds，请求在block_id块存储file_id文件，把文件写入block_id对应块中；
3. primary_ds将数据写入块之后，再给其他slave数据服务器发送在block_id块存储file_id的消息，实现同步；slave服务器成功写入返回之后，primary_ds通过心跳机制给ns报告块的使用情况；
4. primary_ds给客户端回复数据成功写入；

当客户端需要读取文件时，
1. 首先在客户端根据文件名解析出文件所对应的block_id和file_id，然后访问NameServer获取这个block所对应的dataserver地址链表；
2. 接着客户端访问primary_ds读取数据；

以上就客户端存储和读取数据的简要过程，之后会深入介绍文件存储和读取，本篇文章主要是介绍DataServer执行过程；

# DataServer启动过程

---------------------------

首先来看下DataServer启动过程，稍后再分析DataServer处理业务过程。

1. 服务器要开启，首先要找到main函数，DataServer的main函数在/dataserver/service.cpp下面
```
int main(int argc, char* argv[])
{
  tfs::dataserver::DataService service;
  return service.main(argc, argv);
}
```

从代码可以看出先是实例化一个DataService类，然后调用DataService这个类的main函数，接着我们自然而然的会去DataService中查找main函数，接着会发现并没有！这里要先介绍类的继承关系：
```
DataService继承自/common/BaseService
BaseService继承自/common/BaseMain
```

因此我们向上查找，在BaseMain类中找到了main方法，在main方法中，主要处理的是运行程序时，跟在程序后面的参数，最后在main方法中调用start方法
```
 iret = start(argc , argv, daemonize);
```

start方法也是在/common/base_main.cpp文件中，主要做的任务就是处理服务器配置文件以及初始化工作目录，pid目录以及日志目录，最后调用run函数
```
 iret = run(argc, argv);
```

2. 而这个run函数在/common/base_service.cpp的BaseService类中，run函数主要任务就是首先通过调用函数
```
int32_t iret = initialize_network(argv[0]);
```

开启网络模块tbnet两个线程，一个是eventloop线程，负责事件监听，另一个是timeoutLoop线程，负责监控各个客户端连接的情况。在run函数中，接着开启4工作线程，工作线程个数可配置,以及一个时间监控线程（我暂时不知道有啥用），最后调用initialize函数，到达具体服务的初始化操作；

3. 之前是tfs为各个服务抽象出来的公共部分，通过initialize函数达到初始化具体服务的目的；在/dataserver/dataservice.cpp/DataService类中找到了initialize函数,这个函数主要就是初始化dataserver具体信息，比如初始化dataserver的私有目录，设置NameServer的地址，核对网络设备以及自身地址，同时再监听本dataserver端口+1的端口，也就是说一个dataserver监听着两个端口，假如第一个是8200，那么还有端口是8201。在initialize函数中，最后步骤就是开启了2个心跳线程，1个校对线程，1个压缩线程，1个复制线程（可配置）。

至此，dataserver就启动完毕，等待客户端的连接，请求数据。

dataserver默认是有13个线程，我们可以通过pstack或者gdb info thread打印出来，而且除了main主线程，其他线程是根据开启时间，从上至下排列；
```
[root@meitu_6 luodw]# pstack 3875
Thread 13 (Thread 0x7f2ea1b96700 (LWP 3876))://tbnet的事件监听线程
#0  0x00007f2ea1e96163 in epoll_wait () from /lib64/libc.so.6
#1  0x00000000004a61a9 in tbnet::EPollSocketEvent::getEvents(int, tbnet::IOEvent*, int) ()
#2  0x00000000004a2c29 in tbnet::Transport::eventLoop(tbnet::SocketEvent*) ()
#3  0x00000000004a3c49 in tbsys::CThread::hook(void*) ()
#4  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#5  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 12 (Thread 0x7f2ea1195700 (LWP 3877)):// tbnet客户端监控超时监控事件
#0  0x00007f2ea1e59cdd in nanosleep () from /lib64/libc.so.6
#1  0x00007f2ea1e8ee54 in usleep () from /lib64/libc.so.6
#2  0x00000000004a396a in tbnet::Transport::timeoutLoop() ()
#3  0x00000000004a3c49 in tbsys::CThread::hook(void*) ()
#4  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#5  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 11 (Thread 0x7f2e9bfff700 (LWP 3881)):// 工作线程1
#0  0x00007f2ea28da5bc in pthread_cond_wait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x00000000004a0267 in tbnet::PacketQueueThread::run(tbsys::CThread*, void*) ()
#2  0x00000000004a3c49 in tbsys::CThread::hook(void*) ()
#3  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#4  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 10 (Thread 0x7f2e9b5fe700 (LWP 3883)):// 工作线程2
#0  0x00007f2ea28da5bc in pthread_cond_wait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x00000000004a0267 in tbnet::PacketQueueThread::run(tbsys::CThread*, void*) ()
#2  0x00000000004a3c49 in tbsys::CThread::hook(void*) ()
#3  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#4  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 9 (Thread 0x7f2e9abfd700 (LWP 3885)):// 工作线程3
#0  0x00007f2ea28da5bc in pthread_cond_wait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x00000000004a0267 in tbnet::PacketQueueThread::run(tbsys::CThread*, void*) ()
#2  0x00000000004a3c49 in tbsys::CThread::hook(void*) ()
#3  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#4  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 8 (Thread 0x7f2e9a1fc700 (LWP 3886)):// 工作线程4
#0  0x00007f2ea28da5bc in pthread_cond_wait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x00000000004a0267 in tbnet::PacketQueueThread::run(tbsys::CThread*, void*) ()
#2  0x00000000004a3c49 in tbsys::CThread::hook(void*) ()
#3  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#4  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 7 (Thread 0x7f2e997fb700 (LWP 3887))://这就是我暂时不是很清楚的那个时间线程
#0  0x00007f2ea28da98e in pthread_cond_timedwait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x00000000004baf04 in bool tbutil::Cond::timedWaitImpl<tbutil::Mutex>(tbutil::Mutex const&, tbutil::Time const&) const ()
#2  0x00000000004ba145 in tbutil::Monitor<tbutil::Mutex>::timedWait(tbutil::Time const&) const ()
#3  0x00000000004b9459 in tbutil::Timer::run() ()
#4  0x00000000004b5069 in startHook ()
#5  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#6  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 6 (Thread 0x7f2e98dfa700 (LWP 3892)):// 心跳线程1
#0  0x00007f2ea1e59cdd in nanosleep () from /lib64/libc.so.6
#1  0x00007f2ea1e8ee54 in usleep () from /lib64/libc.so.6
#2  0x000000000043c53a in tfs::dataserver::DataService::run_heart(int) ()
#3  0x00000000004b5069 in startHook ()
#4  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#5  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 5 (Thread 0x7f2e983f9700 (LWP 3894)):// 心跳线程2
#0  0x00007f2ea1e59cdd in nanosleep () from /lib64/libc.so.6
#1  0x00007f2ea1e8ee54 in usleep () from /lib64/libc.so.6
#2  0x000000000043c476 in tfs::dataserver::DataService::run_heart(int) ()
#3  0x00000000004b5069 in startHook ()
#4  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#5  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 4 (Thread 0x7f2e979f8700 (LWP 3896)):// 校对线程
#0  0x00007f2ea1e59cdd in nanosleep () from /lib64/libc.so.6
#1  0x00007f2ea1e59b50 in sleep () from /lib64/libc.so.6
#2  0x0000000000438633 in tfs::dataserver::DataService::run_check() ()
#3  0x00000000004b5069 in startHook ()
#4  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#5  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 3 (Thread 0x7f2e96ff7700 (LWP 3897)):// 压缩线程
#0  0x00007f2ea28da5bc in pthread_cond_wait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x000000000042f3a9 in tfs::dataserver::CompactBlock::run_compact_block() ()
#2  0x00000000004b5069 in startHook ()
#3  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#4  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 2 (Thread 0x7f2e8ffff700 (LWP 3899)):// 复制线程
#0  0x00007f2ea28da98e in pthread_cond_timedwait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x000000000042b7ff in tfs::dataserver::ReplicateBlock::run_replicate_block() ()
#2  0x00000000004b5069 in startHook ()
#3  0x00007f2ea28d69d1 in start_thread () from /lib64/libpthread.so.0
#4  0x00007f2ea1e95b6d in clone () from /lib64/libc.so.6
Thread 1 (Thread 0x7f2ea2f02720 (LWP 3875)):// 主线程
#0  0x00007f2ea28da5bc in pthread_cond_wait@@GLIBC_2.3.2 () from /lib64/libpthread.so.0
#1  0x000000000048c4dc in tfs::common::BaseMain::wait_for_shutdown() ()
#2  0x000000000048d632 in tfs::common::BaseMain::start(int, char**, bool) ()
#3  0x000000000048db2d in tfs::common::BaseMain::main(int, char**) ()
#4  0x000000000040f0c0 in main ()
```

因此，dataserver开启之后，总共有13个线程在跑着，最主要的线程是tbnet的事件监听线程和4个工作线程，因为这两个是处理客户端请求最主要的线程；

# dataserver处理请求过程

---------------------------------

dataserver处理客户端的请求过程可比dataserver启动过程复杂的多，先简要说下过程;
> tbnet线程监听到客户端有数据可读，读取数据并将数据封装成packet，放入队列中；之前的四个工作线程一开始都阻塞在条件变量上，当有个packet放入队列并唤醒一个工作线程处理这个packet，处理结束之后，把回复客户端的内容放入链接缓冲区中，并在这个连接上注册一个可写事件，在下一次事件循环中，把回复发送给客户端。

ok，我开始分析吧!

这里就不分析网络模块的线程是怎么创建的，只分析处理过程，因为单独分析tbnet就可以写一篇文章。但是tfs如何创建线程估计就理解一小会，主要过程就是tbnet模块最主要类Transport通过调用start方法把自己传入CThread的start方法中，然后再回调Transport的run方法，实现创建线程的目的；

我们来看下eventLoop线程主要事件回调代码：
```
    bool rc = true;
    if (events[i]._readOccurred) {
        rc = ioc->handleReadEvent();
        //ioc为iocomponent,即将与网络io相关的部分封装在一起，一个f客户端对应一个iocomponent
    }
    if (rc && events[i]._writeOccurred) {
        rc = ioc->handleWriteEvent();
    }
```

listenfd和clientfd对应的iocomponent是不一样的，对于listenfd对应的iocomponent为tcpacceptor.cpp/TCPAcceptor这个类，这个类只有handleReadEvent方法，即将接收的客户端加入事件监听中，并注册可写事件。而clientfd对应的iocomponent为tcpconnnection.cpp/TCPConnection类，这个类的handleReadEvent处理客户端的请求，而handleWriteEvent处理回复客户端事件。

1. 我们从clientfd的iocomponent-->handleReadEvent开始说起：
```
bool TCPComponent::handleReadEvent() {
    _lastUseTime = tbsys::CTimeUtil::getTime();
    bool rc = false;
    if (_state == TBNET_CONNECTED) {
        rc = _connection->readData();
    }
    return rc;
}
```

可以看到在TCPComponent::handleReadEvent方法中，只是简单的调用对应的_connection>readData()方法。接下来，我们深入_connection->readData()方法。在readData方法中，
* 首先调用socket的read方法将客户端的数据读取进_input缓冲区中；
* 接着调用方法_streamer->getPacketInfo，解析出包头;
* 最后调用handlePacket方法处理包；

这个handlePacket方法在TCPConnection类中是找不到的，而是存在该类的父类Connection中，在handlePacket方法中，最重要的就是解析出包，然后调用
```
rc = _serverAdapter->handlePacket(this, packet);
```

来处理包；到这里，可能又要开始迷糊了，这个_serverAdapter是什么鬼？

> 到这里需要先来介绍下tbnet模块的Transport类，为了tbnet模块接口的简单，tbnet就提供了Transport这类给其他模块调用，而这个类主要最主要就是listen方法和start方法；listen方法用于设置监听的套接字，start用于开启tbnet模块的两个线程；

```
IOComponent *Transport::listen(const char *spec, IPacketStreamer *streamer, IServerAdapter *serverAdapter)
```

这个listen方法第一个参数为监听套接字，第二个参数为转码用的streamer，第三个参数为每个服务器处理包的适配器，因此tbnet模块所有的serverAdapter都是从这个listen接口传进去的。我们来看下dataserver调用listen接口：
```
tbnet::IOComponent* com = transport_->listen(spec, streamer_, this);
```

在DataService类调用listen方法时，把自己作为serverAdapter传入tbnet模块，因为DataService继承自base_service,而base_service继承自IServerAdapter，因此DataService可以作为IServerAdapter的子类传入tbnet模块中；现在我们可以看下DataService->handlePacket方法做了什么？

2. 在DataService->handlePacket方法中，最要就是调用push方法，而push方法主要就是将packet存入工作线程队列中
```
bool BaseService::push(BasePacket* packet, bool block)
    {
      return main_workers_.push(packet, work_queue_size_, block);
    }
```

在main_workers_为tbnet的PacketQueueThread类，我们定位到该类的push方法，在push方法中，最重要的就是

```
_cond.lock();
  _queue.push(packet);
  _cond.unlock();
  _cond.signal();
```
将packet存入队列中，并且调用_cond.signal方法唤醒一个工作线程；到这时，tbnet的eventLoop线程即处理结束一个客户端的请求，接下来的处理就交给工作线程处理。

3. 之前有提到，工作线程当初调用/PacketQueueThread/run方法，阻塞在条件变量中，因此可以和eventLoop线程共享packet队列。我们看下某个线程被唤醒后，做了什么？

可以在run方法中，可以看到最重要的一行代码为:
```
if (_handler) {
           ret = _handler->handlePacketQueue(packet, _args);
       }
```

即调用handler->handlePacketQueue方法，之前有提到过，这个_handler即为DataService类，可以定位到DataService->handlePacketQueue方法，在该方法中，根据packet的类型，执行不同的操作：

```
bool DataService::handlePacketQueue(tbnet::Packet* packet, void* args)
   {
     bool bret = BaseService::handlePacketQueue(packet, args);
     if (bret)
     {
       int32_t pcode = packet->getPCode();
       int32_t ret = LOCAL_PACKET == pcode ? TFS_ERROR : TFS_SUCCESS;
       if (TFS_SUCCESS == ret)
       {
         switch (pcode)
         {
           case CREATE_FILENAME_MESSAGE:
             ret = create_file_number(dynamic_cast<CreateFilenameMessage*>(packet));
             break;
           case WRITE_DATA_MESSAGE:
             ret = write_data(dynamic_cast<WriteDataMessage*>(packet));
             break;
           case CLOSE_FILE_MESSAGE:
             ret = close_write_file(dynamic_cast<CloseFileMessage*>(packet));
             break;
    .........................
```

我们以创建一个文件为例，此时执行的是create_file_number方法，在该方法中首先调用DataManagement->create_file方法，执行创建文件的操作；DataManagement专门负责DataServer文件存储各种方法调用，后面再写一篇文章，专门介绍DataServer如何存储文件。

在create_file_number方法中，接下来先定义一个回复给客户端的消息类，并且执行请求消息的reply方法将消息准备回复给客户端。
```
RespCreateFilenameMessage* resp_cfn_msg = new RespCreateFilenameMessage();
      resp_cfn_msg->set_block_id(block_id);
      resp_cfn_msg->set_file_id(file_id);
      resp_cfn_msg->set_file_number(file_number);
      message->reply(resp_cfn_msg);
```
此时的message是一个BasePacket的子类，我们定位到BasePacket->reply方法。

在reply方法中，一开始是先设置回复消息类的一些属性，然后最重要的是调用_connection->postPacket方法:
```
bool bret= connection_->postPacket(packet);
```
在postPacket方法中，我们提取出最重要的两行代码
```
// 将回复客户端的消息packet存入输出队列中
 _outputQueue.push(packet);
// 注册当前连接的可写事件
 _iocomponent->enableWrite(true);
```

4. 在注册可写事件之后，因为eventLoop的事件监听中，先执行可读事件，可读事件结束之后，再执行可写事件，因此上述注册可写事件之后，待所有可读事件执行结束之后，即可直接执行可写事件，把消息回复给客户端。

可写事件的回调函数是

```
 rc = ioc->handleWriteEvent();
```

ok，我们定位到TCPComponent->handleWriteEvent方法，可以看到最主要还是执行TCPConnection->writedata方法

```
rc = _connection->writeData();
```

在TCPConnection->writeData方法中，去除输出队列的第一个消息包，然后调用

```
  ret = _socket->write(_output.getData(), _output.getDataLen());
```

把消息回复给客户端。

上述就是客户端和DataServer一次完整的交互过程。

如果要按编程模型分类，DataServer属于多线程模型，这种多线程模型又区别于memcache，它是某个线程监听所有套接字，然后将客户端的请求封装成消息包，放入公共队列中；接着由4个工作线程同步地去除消息队列的第一个消息包，并执行；这种模式可缺点就是公共队列要加锁同步，有一定开销；优点就是eventLoop线程可以很快的返回，加快处理客户端的请求，然后把可能消耗大量时间的业务处理放在了工作线程，极大加快系统的响应速度，这点和linux内核中断上下文原理类似。

DataServer整体的执行过程就先分析到这，后续可能会分析tbnet模块和DataServer存储数据过程。
