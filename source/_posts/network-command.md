title: 命令netstat,trace和tcpdump
date: 2015-12-30 20:07:29
tags:
- network
- netstat
- trace
- tcpdump
categories:
- linux
toc: true

---

最近在学网络，特别是在用tcpdump命令捕获数据包时，发现网络的几个命令是那么强大，特此，上网搜索了相关资料，总结下这几个命令的用法。从网络接口到tcp层，有ifconfig,route和routetrace,netstat.还有一个抓包命令tcpdump。

# netstat命令

----

netstat命令主要是用于显示各种网络相关信息，如网络连接，路由表，接口状态，多播成员等等。命令用法比较多，初学记住几个常用的就行了。

首先是默认情况下，netstat命令输出所有的连接情况，默认情况下，netstat输出的是所有已连接的tcp,udp和unix域套接字。如下：
```
root@charles-Lenovo:/home/charles# netstat | more
激活Internet连接 (w/o 服务器)
Proto Recv-Q Send-Q Local Address           Foreign Address         State      
tcp        0      0 localhost:49558         localhost:36329         ESTABLISHED
tcp        0      0 localhost:49558         localhost:36377         ESTABLISHED
tcp        0      0 localhost:36377         localhost:49558         ESTABLISHED
tcp        0      0 localhost:36329         localhost:49558         ESTABLISHED
tcp6       1      0 ip6-localhost:46135     ip6-localhost:ipp       CLOSE_WAIT 
活跃的UNIX域套接字 (w/o 服务器)
Proto RefCnt Flags       Type       State         I-Node   路径
unix  20     [ ]         数据报                11336    /dev/log
unix  3      [ ]         流        已连接     17634    
unix  3      [ ]         流        已连接     14118    
unix  3      [ ]         流        已连接     14812    /run/user/1000/pulse/nati
ve
unix  3      [ ]         流        已连接     16987    
unix  3      [ ]         流        已连接     14188    
unix  3      [ ]         流        已连接     17596    
unix  3      [ ]         流        已连接     17482    
```
从输出可以看出，netstat主要就是显示各种连接的状态，包括tcp,udp和unix。这个输出没有udp，因为我没有开启udp程序，当我开启一个udp程序和浏览器时，这时就会显示两个udp连接，一个是我udp程序的连接，一个是浏览器向本地域名服务器解析域名的udp连接：
```
udp        0      0 localhost:59634         localhost:8888          ESTABLISHED
udp        0      0 localhost:52440         charles-Lenovo:domain   ESTABLISHED
```
第一个是我的udp程序调用connect函数之后，出现的连接状态，如果没有connect函数，那么是不会显示udp连接状态的，因为udp是面向无连接。第二个是浏览器向dnsmasq建立udp连接，用于解析域名。当调用getaddinfo函数时，也是会有第二条连接的。linux系统unix域套接字用的比较多，主要是因为性能比tcp/udp好。

1. 列出所有的端口（包括监听和未监听的）
netstat -a
```
root@charles-Lenovo:/home/charles# netstat -a | more
激活Internet连接 (服务器和已建立连接的)
Proto Recv-Q Send-Q Local Address           Foreign Address         State     
tcp        0      0 localhost:mysql         *:*                     LISTEN     
tcp        0      0 charles-Lenovo:domain   *:*                     LISTEN     
udp        0      0 charles-Lenovo:domain   *:*                                
udp        0      0 *:bootpc                *:* 
活跃的UNIX域套接字 (服务器和已建立连接的)
Proto RefCnt Flags       Type       State         I-Node   路径
unix  2      [ ACC ]     流        LISTENING     11264    /run/user/1000/pulse/native
unix  2      [ ACC ]     流        LISTENING     12805    /var/run/mysqld/mysqld.sock
```

2. 只列出所有的tcp连接
netstat -at
3. 只列出所有的udp连接
netstat -au

4. 列出所有处于监听的连接，包括tcp,udp和unix域套接字
netstat -l
```
root@charles-Lenovo:/home/charles# netstat -l
激活Internet连接 (仅服务器)
Proto Recv-Q Send-Q Local Address           Foreign Address         State      
tcp        0      0 localhost:mysql         *:*                     LISTEN     
tcp        0      0 charles-Lenovo:domain   *:*                     LISTEN   
udp        0      0 charles-Lenovo:domain   *:*                                
udp        0      0 *:bootpc                *:*                            
活跃的UNIX域套接字 (仅服务器)
Proto RefCnt Flags       Type       State         I-Node   路径
unix  2      [ ACC ]     流        LISTENING     11264    /run/user/1000/pulse/native
unix  2      [ ACC ]     流        LISTENING     12805    /var/run/mysqld/mysqld.sock
```
5. 只列出tcp监听端口
netstat -lt
6. 只列出udp监听端口
netstat -lu
7. 只列出unix域套接字监听端口
netstat -lx
8. 查看路由表信息
netstat -r
```
root@charles-Lenovo:/home/charles# netstat -r
内核 IP 路由表
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
default         192.168.1.1     0.0.0.0         UG        0 0          0 eth0
192.168.1.0     *               255.255.255.0   U         0 0          0 eth0
```
一般有两条路由信息，一个是默认路由，即目的地地址不在本网络时，通过网络接口eth0，传到网关192.168.1.1这个也就是第一跳路由器的地址；如果目的地地址是在同一个局域网中，即与子网掩码255.255.255.0与之后=192.168.1.0，则没有网关，通过eth0广播询问即可。
9. 查询网络接口列表
netstat -i
```
root@charles-Lenovo:/home/charles# netstat -i
Kernel Interface table
Iface   MTU Met   RX-OK RX-ERR RX-DRP RX-OVR    TX-OK TX-ERR TX-DRP TX-OVR Flg
eth0       1500 0     57318      0      0 0         41328      0      0      0 BMRU
lo        65536 0     13239      0      0 0         13239      0      0      0 LRU
```
10. 找出程序运行的端口
netstat -ap | grep ssh
```
root@charles-Lenovo:/home/charles# netstat -ap | grep ssh
unix  2      [ ACC ]     流        LISTENING     13893    1693/gnome-keyring- 
/run/user/1000/keyring-32r7ap/ssh
```
这里ssh服务器居然是建立unix套接字，这让我很费解，怎么实现远程连接的？

之后就是与一些命令组合，例如，awk,sed,grep等等，输出各个字段的信息，这后面在学习了。

# route命令

----

这个命令主要是用于查看路由表，添加路由信息，设置网关等等；默认输出的是路由表信息；
```
root@charles-Lenovo:/home/charles# route
内核 IP 路由表
目标            网关            子网掩码        标志  跃点   引用  使用 接口
default         192.168.1.1     0.0.0.0         UG    0      0        0 eth0
192.168.1.0     *               255.255.255.0   U     1      0        0 eth0
```
route -n这个和route的区别就是：route显示的主机名称，而route -n显示的IP地址

下面说下主要几个标志的意义：
+ U (route is up)：该路由是启动的；
+ H (target is a host)：目标是一部主机 (IP) 而非网域；
+ G (use gateway)：需要透过外部的主机 (gateway) 来转递封包；
+ R (reinstate route for dynamic routing)：使用动态路由时，恢复路由资讯的旗标；
+ D (dynamically installed by daemon or redirect)：已经由服务或转 port 功能设定为动态路由；
+ M (modified from routing daemon or redirect)：路由已经被修改了；
+ !  (reject route)：这个路由将不会被接受(用来抵挡不安全的网域！)

1. 向路由表添加一个路由信息
一般来说，都是为了能访问别的子网才设置路由的，比如说，你的主机处于192.168.10.0/24，而你想访问192.168.20.0/24网的主机，当然你知道一个网关IP，例如192.168.10.1（必须和你主机处于同一子网），那么，你可以这样配置路由。

添加路由
```
route add -net 192.168.20.0 netmask 255.255.255.0 gw 192.168.10.1
```
删除路由
```
route del -net 192.168.20.0 netmask 255.255.255.0
```
这个命令最主要的用法就是查看路由表，添加路由和删除路由器。

# ifconfig命令

---

这个命令平常使用最主要的功能就是，查看网络接口的信息，例如物理地址，ip地址，掩码等等。其他就是设置网络接口开关，设置mtu等等。
```
root@charles-Lenovo:/home/charles# ifconfig
eth0      Link encap:以太网  硬件地址 44:37:e6:53:d7:8c  
          inet 地址:192.168.1.151  广播:192.168.1.255  掩码:255.255.255.0
          inet6 地址: fe80::4637:e6ff:fe53:d78c/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  跃点数:1
          接收数据包:63010 错误:0 丢弃:0 过载:0 帧数:0
          发送数据包:45853 错误:0 丢弃:0 过载:0 载波:0
          碰撞:0 发送队列长度:1000 
          接收字节:54436715 (54.4 MB)  发送字节:6200233 (6.2 MB)
          中断:20 Memory:fe400000-fe420000 

lo        Link encap:本地环回  
          inet 地址:127.0.0.1  掩码:255.0.0.0
          inet6 地址: ::1/128 Scope:Host
          UP LOOPBACK RUNNING  MTU:65536  跃点数:1
          接收数据包:15778 错误:0 丢弃:0 过载:0 帧数:0
          发送数据包:15778 错误:0 丢弃:0 过载:0 载波:0
          碰撞:0 发送队列长度:0 
          接收字节:13352760 (13.3 MB)  发送字节:13352760 (13.3 MB)
```
1. 启动关闭指定网卡
```
ifconfig eth0 up
ifconfig eth0 down
```
第一个为启动eth0网卡，第二个为关闭eth0网卡，但是如果是ssh登陆linux，则要小心了，因为关闭之后，就连不上了，除非有两个网卡。

2. 为网卡配置和删除IPv6地址
```
ifconfig eth0 add 33ffe:3240:800:1005::2/64 为网卡eth0配置IPv6地址；
ifconfig eth0 add 33ffe:3240:800:1005::2/64 为网卡eth0删除IPv6地址；
```
练习的时候，ssh登陆linux服务器操作要小心，关闭了就不能开启了，除非你有多网卡。

3. 用ifconfig修改MAC地址
```
ifconfig eth0 hw ether 00:AA:BB:CC:DD:EE
```
4. 配置ip地址
```
ifconfig eth0 192.168.120.56 
给eth0网卡配置IP地：192.168.120.56
 ifconfig eth0 192.168.120.56 netmask 255.255.255.0 
给eth0网卡配置IP地址：192.168.120.56 ，并加上子掩码：255.255.255.0
ifconfig eth0 192.168.120.56 netmask 255.255.255.0 broadcast 192.168.120.255
/给eth0网卡配置IP地址：192.168.120.56，加上子掩码：255.255.255.0，加上个广播地址：
192.168.120.255
```
5. 启用和关闭ARP协议
```
ifconfig eth0 arp 开启网卡eth0 的arp协议；
ifconfig eth0 -arp 关闭网卡eth0 的arp协议；
```
6. 设置最大传输单元
```
ifconfig eth0 mtu 1500
```
ifconfig后面这些命令选项平常使用用得少，记得如何查看自己的ip地址是最关键。

# tcpdump命令

---

这个命令主要用于抓包，这也是我最喜欢的 命令之一，太强大了.当udp程序收到icmp不可达数据包时，用户程序是不会知道的，所以用tcpdump看到，因为tcpdump可以解析所有到大网络层的数据包，包括icmp，arp等等。当然还有udp,tcp。

1. 默认启动
```
tcpdump
```
普通情况下，直接启动tcpdump将监视第一个网络接口上所有流过的数据包。
2. 监视指定网络接口的数据包
```
tcpdump -i lo
charles@charles-Lenovo:~/mydir/mycode$ sudo tcpdump -i lo 
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on lo, link-type EN10MB (Ethernet), capture size 65535 bytes
11:16:16.541533 IP localhost.44530 > localhost.8888: UDP, length 6
11:16:16.541558 IP localhost > localhost: ICMP localhost udp port 8888 unreachable, length 42
```
这是我当初在线测试connect函数时写的程序，不开启服务器，开启客户端，然后输入数据，之后服务器会返回不可达的ICMP包文消息。默认监听eth0，我们可以指定tcpdump监听回环接口。
3. 指定监听tcp或者udp
```
tcpdump tcp
tcpdump udp
```
4. 指定监听的主机，可以是主机名或者ip
```
tcpdump host Charles
tcpdump host 192.168.1.151
```
5. 指定监听的端口
```
tcpdump port 8888
```
6. 截获主机hostname发送或接收的所有消息
```
截获主机hostname发送的所有数据
tcpdump -i eth0 src host hostname
监视所有送到主机hostname的数据包
tcpdump -i eth0 dst host hostname
```
7. 监视指定主机和端口的数据包
```
如果想要获取主机210.27.48.1接收或发出的telnet包，使用如下命令
tcpdump tcp port 23 and host 210.27.48.1
对本机的udp 123 端口进行监视 123 为ntp的服务端口
tcpdump udp port 123 
```
初学阶段先了解这么多，就够了。后面有需要，在深入学习。










