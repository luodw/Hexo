title: linux网络编程udp学习读书笔记
date: 2015-12-18 20:34:01
tags:
- socket
- udp
- 网络编程
categories:
- socket
toc: true

---
linux下网络编程主要就是tcp/udp协议,虽然还有个sctp,但是用的并不多,所以这里就先不写了.tcp为面向连接,可靠传输协议,为了实现可靠,指定了一些重要的机制,例如三次握手,拥塞控制,发送确认机制等等.而udp是无连接不可靠传输协议,所以对于udp而言,服务器和客户端并没有连接的概念,而是二者之间的读写就是一次性结束.先来看下udp传输模型.

# udp传输模型

----

udp传输模型如下图所示,图来自**UNIX网络编程卷1:套接字联网API**,
![udp传输模型](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_048.png "")
如图所示,对于服务器端,由以下步骤:
1. 调用socket函数获得套接字Serverfd;
2. 调用bind函数绑定服务器端本地地址和端口,一般情况下绑定地址为ANY_INADDR,即绑定到所有地址,如果是多宿主服务器,则有ip1,ip2,...,127.0.0.1个ip地址.
3. 调用recvfrom函数并阻塞等待用户数据到达.
4. 处理客户端的数据,并调用sendto函数返回给用户.

对于udp客户端而言,主要有以下几个步骤:
1. 调用socket获得套接字Clientfd;
2. 调用sendto向服务器端发送数据;
3. 调用recvfrom阻塞等待服务端返回的数据;
4. 调用close关闭这个Clientfd套接字;

由于udp面向无连接,所以每次发送数据都要指定目的地的ip地址和端口,所以必须调用sendto函数.

当客户端向服务器发送一个数据报,然后数据报在网络中迷路走丢了,这时客户端就会一直阻塞在recvfrom上,永远阻塞;但是服务器是有给客户端回应的,只是没有传到用户态.我们可以通过tcpdump查看,服务给客户端发送了ICMP报文,如下:
![ICMP报文](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_049.png "");
这个也叫异步错误,因为这错误是sendto犯下,却在recvfrom收到ICMP报文.

tcp服务器是并发服务器,udp是迭代服务器,之所以为迭代服务器,是因为udp服务器只有一个udp套接字,然后这个套接字有个缓冲区,任何客户端发送给这个套接字的数据都缓存在那个缓冲区,然后用户进程以FIFO从缓存区读取数据报.

如果udp客户端是多宿的,那么如果客户端没有绑定到哪个具体的ip地址,则端口是由第一次sendto时确定的临时端口,而且之后不变,这原因应该就是一个进程确定一个端口.然后ip地址会随着每次发送数据报而变化.这种变化主要是查找路由时决定的.

# udp调用connect函数

------


udp编程主要两种模式,一种是不调用connect,一种是调用connect函数.当调用connect函数之后,这时udp就分为如下两种:
1. 未连接UDP套接字,新创建的UDP套接字默认如此;
2. 已连接UDP套接字,对UDP套接字调用connect函数的结果;

已连接的套接字比未连接的套接字,发生了三个变化:
1. 我们没必要在输出函数上指定ip地址和端口.即我们不用sendto,而是改用write或send,写到套接字上的任何内容都发送到connect指定的协议地址.注意:sendto也是可以用的.
2. 我们没必要调用recvfrom函数以获得数据报的发送者,而改用read,recv或recvmsg;这样这个ip地址只接收connect地址中的数据报,即这个udp套接字仅仅与一个ip地址交换数据报.

3. 已连接UDP套接字引发的异步错误会返回给它们所在的进程,而未连接udp套接字不会接收任何异步错误,这个后面例子程序有说明.

如果给一个udp多次调用connect,则有两个作用:
1. 指定新的ip地址和端口号;
2. 断开套接字;

对于第一点,TCP是只能调用一次connect函数,而udp是可以多次的,这样就可以指定新的ip地址和端口号;

对于第二点,如果想关闭套接字,需要将地址族改为AF_UNSPEC.

调用connect性能的影响:当没调用connect时,如果要发送两个数据报,则需要以下步骤:
* 连接套接字;
* 输出第一个数据报;
* 断开套接字连接;
* 连接套接字;
* 输出第二个数据报;
* 断开套接字连接;

其实当第二次发送数据时,因为ip地址已经在高速缓存中,所以第二次就没必要查找路由表了.

当调用connect函数之后,
* 连接套接字,
* 输出第一个数据报;
* 输出第二个数据报;

这种情况下,内核只复制一次含有目的地址的ip地址和端口号的套接字地址结构,而调用两次sendto时需要两次复制.

# 我的测试程序

-----

下面是我写的测试程序,客户端带connect函数,所以可以返回异步通知.服务器端如下:
```
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#define MAXLINE 1024
int main(void)
{
	int n;
	socklen_t len;
	char mesg[MAXLINE],sendline[MAXLINE],strip[MAXLINE];
	char *ptr;
	struct sockaddr_in servaddr,cliaddr;
	int sockfd;
	sockfd=socket(AF_INET,SOCK_DGRAM,0);
	if(sockfd==-1)
	{
		fprintf(stderr, "%s\n","socket  error!\n" );
		exit(-1);
	}
	bzero(&servaddr,sizeof(servaddr));
	servaddr.sin_family=AF_INET;
	servaddr.sin_addr.s_addr=htonl(INADDR_ANY);
	servaddr.sin_port=htons(8888);

	bind(sockfd,(struct sockaddr*)&servaddr,sizeof(servaddr));

	for(;;)
	{
		memset(sendline,0,sizeof(sendline));
		snprintf(sendline, MAXLINE,"Come from the server:");
		len=sizeof(cliaddr);
		n=recvfrom(sockfd,mesg,MAXLINE,0,(struct sockaddr*)&cliaddr,&len);
		mesg[n]='\0';
		ptr=sendline+strlen(sendline);
		memcpy(ptr,mesg,n+1);
		printf("receive from client %s ,port is %d  mesg  is %s",inet_ntop(AF_INET ,&cliaddr.sin_addr,strip,len),ntohs(cliaddr.sin_port) ,mesg );
		sendto(sockfd,sendline ,strlen(sendline),0,(struct sockaddr*)&cliaddr,len);
	}
}
```
客户端程序如下:
```
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#define MAXLINE 1024
int main(int argc,char * argv[])
{
	int n;
	char mesg[MAXLINE],readline[MAXLINE+1];
	struct sockaddr_in cliaddr2;
	int sockfd;
	sockfd=socket(AF_INET,SOCK_DGRAM,0);
	if(sockfd==-1)
	{
		fprintf(stderr, "%s\n","socket  error!\n" );
		exit(-1);
	}
	bzero(&cliaddr2,sizeof(cliaddr2));
	cliaddr2.sin_family=AF_INET;
	inet_aton(argv[1], &cliaddr2.sin_addr);
	cliaddr2.sin_port=htons(8888);
	connect(sockfd,(struct sockaddr*)&cliaddr2,sizeof(cliaddr2));
	while(fgets(mesg,MAXLINE,stdin)!=NULL)
	{
		write(sockfd,mesg,strlen(mesg));
		n=read(sockfd,readline,MAXLINE);
		if(n<0)
		{
			perror("read error");
			exit(-1);
		}
		readline[n]='\0';
		printf("%s",readline);
	}
	return 0;
}
```
程序输出如下:服务端
```
➜  mycode  ./udpServer                 
receive from client 127.0.0.1 ,port is 54956  mesg  is hello world!
receive from client 127.0.0.1 ,port is 54956  mesg  is nice to meet you!
```
客户端如下:
```
➜  mycode  ./udpClient 127.0.0.1
hello world!
Come from the server:hello world!
nice to meet you!
Come from the server:nice to meet you!

```
当服务器没开启时,这时客户端向服务器发送请求,recvfrom将返回一个错误:
```
➜  mycode  ./udpClient 127.0.0.1
see you again!
read error: Connection refused
➜  mycode  
```














