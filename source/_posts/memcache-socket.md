title: memcache源码中一些网络设置
date: 2016-01-21 20:29:29
tags:
- memcache
- socket
categories:
- memcache
toc: true

---

memcache网络这一块内容，其实就是调用linux下的网络接口，看过apue和unp，这些接口都听熟悉的，今天主要是分析下，在一个完整的服务器端软件，需要对socket设置些什么．

# SO_KEEPALIVE选项

---

对于高并发的服务器，服务器会有很多客户端连接，如果有些客户端突然断电，因为没有给服务器发送数据，所以服务器也不知道这个客户端已＂死＂，这样会占着服务器一个文件描述符，如果有很多这样的客户端，这样必然会降低服务器端的并发性．还好tcp套接字有一个保持存活的选项．即如果在２小时(/proc/sys/net/ipv4/tcp_keepalive_time 7200 即2小时)内该套接字的任何一方向上都没有数据交换，TCP就自动给对方发送一个保持存活探测分节(keep-alive probe)，这是对端必须响应的一个TCP分节．网络编程那本书上会说，保活分节会导致以下三种情况发生
1. client端连接正常,返回一个ACK.server端收到ACK后重置计时器,在2小时后在发送探测.如果2小时内连接上有数据传输,那么在该时间的基础上向后推延2小时发送探测包;
2. 客户端异常关闭,或网络断开。client无响应,server收不到ACK,在一定时间(/proc/sys/net/ipv4/tcp_keepalive\_intvl 75 即75秒)后重发keepalive packet, 并且重发一定次数(/proc/sys/net/ipv4/tcp_keepalive_probes 9 即9次);，如果还是没有回应，则放弃，套接字关闭；
3. 客户端曾经崩溃,但已经重启.server收到的探测响应是一个复位,该套接字被置为ECONNREST，套接字本身则被关闭．
我们可以在编程实现中通过调用setsockopt函数来修改这三个变量;
```
int                 keepIdle =1800 ;//半小时
int                 keepInterval = 60;//第二次开始，每个一分钟发送一次
int                 keepCount = 10;//总共发送10个保活探测分节
Setsockopt(listenfd, SOL_TCP, TCP_KEEPIDLE, (void *)&keepIdle, sizeof(keepIdle));
Setsockopt(listenfd, SOL_TCP,TCP_KEEPINTVL, (void *)&keepInterval, sizeof(keepInterval));
Setsockopt(listenfd,SOL_TCP, TCP_KEEPCNT, (void *)&keepCount, sizeof(keepCount)); 
```

# SO_REUSEADDR选项

---

经常在开启一个服务器之后，处于某些原因需要重启，我们经常做的是关闭服务器，然后马上开启，这时经常会出现＂Port is already in use＂的错误，这是因为，计算机上不允许两个进程绑定到同一个端口．上述出现错误的原因是服务器刚关闭时，还处于time_wait状态，还没有完全释放端口，所以重用会报错．但是tcp提供一个选项SO_REUSEADDR来设置处于time_wait的端口重用．

网络编程那本书解释了这个选项有四个用途，但是我觉得实际应用中，记者这个上述说的功能即可．

# SO_LINGER选项

----

在讲这个选项之前，可以先了解下shutdown和close这两个函数的区别．
1. close函数主要是把描述符的引用计数减一，仅在该计数变为０时，才关闭这个套接字．当调用close(fd)时，这时就不能往这个fd读写数据了，然而tcp会尝试发送已排队等待发送到对端的任何数据，最后再发送FIN．
2. shutdown函数依赖与参数howto，但是它不会将描述符引用计数减一而是直接切断连接．

shutdown函数可以关闭一半，也可以全关闭，取决为howto
1. SHUT_RD　关闭连接的读这一半－－套接字不再有数据可以接收，而且该套接字中现有的数据都被丢弃．进程不能对该套接字调用任何读函数．
2. SHUT_WR　关闭连接的写一半－－对于TCP套接字，这称为半关闭．当前留在套接字发送缓冲区中的数据将被发送掉，后跟TCP正常终止序列．不管套接字引用计数是否为0，写半部照样关闭．进程不能对套接字调用任何写函数．
3. SHUT_RDWR　连接的读半部和写半部都关闭．这等于调用两次shutdown，一次关闭读，一次关闭写．

对于close减少引用计数，主要是用在多进程环境中，子进程继承父进程的fd，我在一篇博客上看到一个例子，
```
/* First  Sample client fragment, 
 * 多余的代码及变量的声明已略       */  
   s=connect(...);  
   if( fork() ){   /*      The child, it copies its stdin to the socket              */  
       while( gets(buffer) >0)  
           write(s,buf,strlen(buffer));  
           close(s);  
           exit(0);  
   }  
   else {          /* The parent, it receives answers  */  
        while( (n=read(s,buffer,sizeof(buffer)){  
            do_something(n,buffer);  
            /* Connection break from the server is assumed  */  
            /* ATTENTION: deadlock here                     */  
         wait(0); /* Wait for the child to exit          */  
         exit(0);  
    } 
```
其实就是子进程从stdio输入数据，然后发给服务器，父进程从服务器接收数据．当子进程收到EOF时，则close(fd)，但是这个只是将引用计数减一，父进程的fd还存活着，且一直阻塞在read调用上．如果子进程中的fd调用shutdown，则会关闭这个套接字．

好，来看下SO_LINGER这个选项．首先要知道的是close函数调用之后，会立即返回到用户态，然后发送缓冲区的数据将继续发送，最后接FIN．但是可以通过SO_LINGER这个选项改变．

```
struct linger {
     int l_onoff; /* 0 = off, nozero = on */
     int l_linger; /* linger time */
};
```
第一个参数为这个选项的开关，第二个参数为延迟时间
有三种情况:
1. 置 l_onoff为0，则该选项关闭，l_linger的值被忽略，等于内核缺省情况，close调用会立即返回给调用者，如果可能将会传输任何未发送的数据；
2. 设置 l_onoff为非0，l_linger为0，则套接口关闭时TCP夭折连接，TCP将丢弃保留在套接口发送缓冲区中的任何数据并发送一个RST给对方，而不是通常的四分组终止序列，这避免了TIME_WAIT状态；
3. 设置 l\_onoff 为非0，l\_linger为非0，当套接口关闭时内核将拖延一段时间（由l_linger决定）。如果套接口缓冲区中仍残留数据，进程将处于睡眠状态，直 到（a）所有数据发送完且被对方确认，之后进行正常的终止序列（描述字访问计数为0）或（b）延迟时间到。此种情况下，应用程序检查close的返回值是非常重要的，如果在数据发送完并被确认前时间到，close将返回EWOULDBLOCK错误且套接口发送缓冲区中的任何数据都丢失。close的成功返回仅告诉我们发送的数据（和FIN）已由对方TCP确认，它并不能告诉我们对方应用进程是否已读了数据。如果套接口设为非阻塞的，它将不等待close完成。 

# TCP_NODELAY

----

TCP_NODELAY选项在redis源码中也有看到，当初不理解这个的用法，现在看了网络编程之后，对这个选项还是有点理解．TCP_NODELAY是为了关闭Nagle's Algorithm．

Nagles Algorithm是为了提高带宽利用率设计的算法，其做法是合并小的TCP包为一个，避免了过多的小报文的TCP头头所浪费的宽带．如果开启了这个算法(默认),则协议栈会积累数据直到以下两个条件之一满足的时候才真正发送出去:
1. 积累的数据量达到最大的TCP Segment Size
2. 收到了一个Ack

还有一个算法经常和Nagles Algorithm算法配合使用，称为TCP Delayed Acknoledgement，这个算法也是为了类似的目的被设计出来的，它的作用就是延迟Ack包的发送，使得协议栈有机会合并多个Ack，提高网络性能．

下面给出网络编程上的一张图片，说明Nagles算法运行机制
![Nagles算法](http://7xjnip.com1.z0.glb.clouddn.com/ldw-%E9%80%89%E5%8C%BA_055.png "")
假设每个字符间隔正好是250ms，到服务器的RTT为600ms．当禁用Nagles算法时，每隔250ms准时发送一个字符．而禁用Nagles算法之后，第一次发送不需要等待，但是第二发送必须等待接收到第一次发送的ack才能发送，这样第二和第三个字符就可以一起发送．

可以这样设想，2个(1字节的数据+20字节的tcp头)和2个2字节的数据+20字节的tcp头，首先提高了网络利用率，其次减少了网络上tcp包数量，降低网络拥堵．

如果对端开启ack延滞算法，那么发送端就可以积累更多的包为一个tcp包．对端的ack会在以下两种情况下发回发送端
1. 超时时间到，默认为40ms
2. 对端有数据回显，则可以捎带上这个ack

有以下两种情况不适合使用Nagles算法，
1. 对于其服务器不在相反方向产生数据以便携带ACK的客户来说，ACK延滞算法出现问题．客户会明显感到延迟，因为客户TCP需要等待服务器的ACK延滞定时器超时才能才继续给服务器发送数据．这些客户需要禁用Nagles算法，TCP_NODELAY算法就起到这个作用．
2. 另一类不适用使用Nagles算法和TCP延滞算法的客户是以若干小片数据向服务器发送单个逻辑请求的客户．例如像memcache的set命令分为两次发送，而且每次都是小片数据，因为第一次发送set键值部分，服务器是不会回复数据，所以必须等待ack延滞超时才能发送set命令值部分，这就出现延迟了．所以memcache必须关闭Nagles算法．redis有些命令也是类似

以上就是一个服务器端软件经常碰到的socket选项设置．还有一个需要提到的就是需要捕获SIGPIPE信号，因为如果一个客户端突然断线，服务器向他写一个数据包客户端会发送RST给服务器，如果服务器再向客户发送数据，则系统给服务器发送SIGPIPE信号，默认是退出，所以必须捕获SIGPIPE信号．











































