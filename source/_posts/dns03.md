title: 域名解析之dig,host,nslookup命令
date: 2015-12-27 18:30:04
tags:
- linux
- 命令
categories:
- linux

toc: true

---

上篇博客稍微介绍了域名服务器和和getaddrinfo等函数,这篇文章想好好总结下关于域名解析命令的使用,主要有以下三个命令:dig,host和nslookup。这三个命令主要是用于本地域名查询。原理就是当调用这个三个命令时，内核会向本地域名服务器查询，即dnsmasq这个守护进程。当dnsmasq有缓存所需要查询的域名时，直接返回，如果没有，则递归向外界的域名服务器查询。

# dig命令

---

dig命令的使用方法很简单,主要就是dig +域名.
1. dig baidu.com即可输出baidu.com这个域名的ip地址,所在的域名服务器以及域名服务器的地址;如下;
```
:charles@charles-Lenovo:~/mydir/Hexo/source/_posts$ dig baidu.com

; <<>> DiG 9.9.5-3ubuntu0.6-Ubuntu <<>> baidu.com
dig这个程序的版本号和要查询的域名
;; global options: +cmd
表示可以在命令后面加选项
;; Got answer:
以下是获取信息的内容
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 60954
;; flags: qr rd ra; QUERY: 1, ANSWER: 4, AUTHORITY: 5, ADDITIONAL: 6
这个是返回信息的头部:
opcode: 操作码,QUERY,代表是查询操作;
status: 状态,NOERROR,代表没有错误;
id: 编号,60954,16bit数字,在dns协议中,通过编号匹配返回和查询.
flags: 标志,如果出现就表示有标志,如果不出现,就表示为设置标志:
qr query,查询标志,代表是查询操作
rd recursion desired,代表希望进行递归查询操作;
ra recursive available在返回中设置,代表查询的服务器支持递归查询操作;
aa Authoritative Answer权威回复,如果查询结果由管理域名的域名服务器而不是缓存服务器提供的,则
称为权威回复;
QUERY 查询数,1代表一个查询,对应下面QUESTION SECTION的记录数
ANSWER 结果数,4代表有4个结果,对应下面的ANSWER SECTION中的记录数
AUTHORITY 权威域名服务器记录数，5代表该域名有5个权威域名服务器，可供域名解析用。对应
下面AUTHORITY SECTION
ADDITIONAL 格外记录数，6代表有6项格外记录。对应下面 ADDITIONAL SECTION。
;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
这个不知道啥意思
;; QUESTION SECTION:
;baidu.com.			IN	A
查询部分,从做到右部分意义如下:
1、要查询的域名，这里是baidu.com.，'.'代表根域名，com顶级域名，baidu二级域名
2、class，要查询信息的类别，IN代表类别为IP协议，即Internet。还有其它类别，比如chaos等，由于
现在都是互联网，所以其它基本不用。
3、type，要查询的记录类型，A记录(Address)，代表要查询ipv4地址。AAAA记录，代表要查询ipv6地址。
;; ANSWER SECTION:
baidu.com.		211	IN	A	123.125.114.144
baidu.com.		211	IN	A	111.13.101.208
baidu.com.		211	IN	A	220.181.57.217
baidu.com.		211	IN	A	180.149.132.47
回应部分，回应都是A记录，A记录从左到右各部分意义：
1、对应的域名，这里是baidu.com.，'.'代表根域名，com顶级域名，baidu二级域名
2、TTL，time ro live，缓存时间，单位秒。76，代表缓存域名服务器，可以在缓存中保存76秒该记录。
3、class，要查询信息的类别，IN代表类别为IP协议，即Internet。还有其它类别，比如chaos等由于现在都是互联网，所以其它基本不用。
4、type，要查询的记录类型，A记录，代表要查询ipv4地址。AAAA记录，代表要查询ipv6地址。
5、域名对应的ip地址。

;; AUTHORITY SECTION:
baidu.com.		52340	IN	NS	dns.baidu.com.
baidu.com.		52340	IN	NS	ns3.baidu.com.
baidu.com.		52340	IN	NS	ns2.baidu.com.
baidu.com.		52340	IN	NS	ns7.baidu.com.
baidu.com.		52340	IN	NS	ns4.baidu.com.
权威域名部分，回应都是NS记录(Name Server)，NS记录从左到右各部分意义：
1、对应的域名，这里是baidu.com.，'.'代表根域名，com顶级域名，baidu二级域名
2、TTL，time ro live，缓存时间，单位秒。63948，代表缓存域名服务器，可以在缓存中保存63948秒
该记录。
3、class，要查询信息的类别，IN代表类别为IP协议，即Internet。还有其它类别，比如chaos等，由于
现在都是互联网，所以其它基本不用。
4、type，要查询的记录类型，NS，Name Server，NS记录，代表该记录描述了域名对应的权威域名
解析服务器
5、域名对应域名对应的权威域名解析服务器。由于ns2.baidu.com.是baidu.com.的子域名，而解析子
域名，又需要主域名的信息，为了打破这个死循环，需要在下面的额外记录中提供该服务器的ip地址。

;; ADDITIONAL SECTION:
dns.baidu.com.		55285	IN	A	202.108.22.220
ns2.baidu.com.		60825	IN	A	61.135.165.235
ns3.baidu.com.		79196	IN	A	220.181.37.10
ns4.baidu.com.		79196	IN	A	220.181.38.10
ns7.baidu.com.		55194	IN	A	119.75.219.82
额外记录部分，这里都是A记录，A记录从左到右各部分意义：
1、对应的域名，这里是dns.baidu.com.，'.'代表根域名，com顶级域名，baidu二级域名，dns是三级域名。
2、TTL，time ro live，缓存时间，单位秒。13284，代表缓存域名服务器可以在缓存中保存13284秒该记录。
3、class，要查询信息的类别，IN代表类别为IP协议，即Internet。还有其它类别，比如chaos等，由于
现在都是互联网，所以其它基本不用。
4、type，要查询的记录类型，A记录，代表要查询ipv4地址。AAAA记录，代表要查询ipv6地址。
5、域名对应的ip地址。

;; Query time: 2 msec
查询耗时
;; SERVER: 127.0.1.1#53(127.0.1.1)
查询使用的服务器地址和端口,其实就是本地DNS域名服务器
;; WHEN: Sun Dec 27 19:27:16 CST 2015
查询的时间
;; MSG SIZE  rcvd: 272
回应的大小。收到(rcve, recieved)256字节。
```
从以上dig结果中熟悉了2种DNS记录,A记录和NS记录.了解了dig的收到消息的各部分意义之后,接下来就可以看看dig命令的一些其他用法.
2. dig baidu.com
这个默认就是查询A记录,由以上可知,还有NS记录
3. dig baidu.com ns
这个是只查询NS记录,输出和dig baidu.com几乎一样,除了没有baidu.com的A记录.
4. dig baidu.com soa
查询SOA记录,SOA资源记录表明,此DNS服务器是为该DNS域中的数据的信息的最佳来源,这个命令的输出,比dig baidu.com ns命令多出一行,表示最佳的DNS域名服务器:
```
;; ANSWER SECTION:
baidu.com.		7200	IN	SOA	dns.baidu.com. sa.baidu.com. 2012128552 300 
300 2592000 7200
各项意义如下:
1、SOA SOA记录
2、dns.baidu.com.  Nameserver，该域名解析使用的服务器
3、dns.baidu.com  Email address，该域名管理者的电子邮件地址，第一个'.'代表电子邮件中的'@'，
所以对应的邮件地址为:sa@baidu.com
4、2012128552 Serial number，反映域名信息变化的序列号。每次域名信息变化该项数值需要增大。
格式没有要求，但一般习惯使用YYYYMMDDnn的格式，表示在某年(YYYY)、月(MM)、日(DD)进行了第几
次(nn)修改。
5、300 Refresh，备用DNS服务器隔一定时间会查询主DNS服务器中的序列号是否增加，即域文件是否有
变化。这项内容就代表这个间隔的时间，单位为秒。
6、300 Retry，这项内容表示如果备用服务器无法连上主服务器，过多久再重试，单位为秒。通常小于
刷新时间。
7、2592000 Expiry，当备用DNS服务器无法联系上主DNS服务器时，备用DNS服务器可以在多长时间内
认为其缓存是有效的，并供用户查询。单位为秒。1209600秒为2周。
8、7200 Minimum，缓存DNS服务器可以缓存记录多长时间，单位为秒。这个时间比较重要，太短会增加主
DNS服务器负载。如果太长，在域名信息改变时，需要更长的时间才能各地的缓存DNS服务器才能得到变化
信息。
```
5. dig baidu.com mx
查询mx记录,表示发送到此域名的邮件将被解析到的服务器IP地址.

6. dig baidu.com +trace
这个很有用,可以看到dig程序是怎么一步一步的解析出域名的IP地址.原理就是DNS递归查询.先从本地域名服务器获取所有的"."根域名服务器,然后从某个根域名服务器获取所有一级域名com服务器,接着从某个一级域名com服务器获取所有的二级域名baidu.com的所有域名服务器,最后从某个二级域名baidu.com服务器获取所有的记录.就是A记录和NS记录.

# nslookup命令

---

了解了dig命令获取的消息结构之后,nslookup会好理解的多.nslookup支持交互模式和非交互模式,进入交互模式有如下方法:
1. 直接输入nslookup命令，不加任何参数，则直接进入交互模式，此时nslookup会连接到默认的域名服务器（即/etc/resolv.conf的第一个dns地址）。
2. 是支持选定不同域名服务器的。需要设置第一个参数为“-”，然后第二个参数是设置要连接的域名服务器主机名或IP地址。例如可以设置本机为域名服务器nslookup - 127.0.0.1

进入非交互模式,即一次性执行一次查询操作就结束,如果你直接在nslookup命令后加上所要查询的IP或主机名，那么就进入了非交互模式。当然，这个时候你也可以在第二个参数位置设置所要连接的域名服务器。

但我们平时一般是使用在交互模式之下,主要是因为强大,nslookup默认情况下是执行查找A记录,如下:
```
charles@charles-Lenovo:~/mydir/Hexo/source/_posts$ nslookup 
> baidu.com
Server:		127.0.1.1
Address:	127.0.1.1#53

Non-authoritative answer:
Name:	baidu.com
Address: 220.181.57.217
Name:	baidu.com
Address: 123.125.114.144
Name:	baidu.com
Address: 180.149.132.47
Name:	baidu.com
Address: 111.13.101.208
> 
```
如果要设置查找不同查询信息,可以用set type=ns,a,mx等等

查询ns信息:
```
> set type=ns
> baidu.com
Server:		127.0.1.1
Address:	127.0.1.1#53

Non-authoritative answer:
baidu.com	nameserver = ns7.baidu.com.
baidu.com	nameserver = dns.baidu.com.
baidu.com	nameserver = ns3.baidu.com.
baidu.com	nameserver = ns2.baidu.com.
baidu.com	nameserver = ns4.baidu.com.

Authoritative answers can be found from:
dns.baidu.com	internet address = 202.108.22.220
ns2.baidu.com	internet address = 61.135.165.235
ns3.baidu.com	internet address = 220.181.37.10
ns4.baidu.com	internet address = 220.181.38.10
ns7.baidu.com	internet address = 119.75.219.82
> 
```
查询mx信息:set type=mx,输出比ns的输出多出mx的信息:
```
Non-authoritative answer:
baidu.com	mail exchanger = 20 mx1.baidu.com.
baidu.com	mail exchanger = 20 jpmx.baidu.com.
baidu.com	mail exchanger = 10 mx.n.shifen.com.
baidu.com	mail exchanger = 20 mx50.baidu.com.
```

# host命令

---

host命令也很简单,默认输出只有A和MX记录:
```
charles@charles-Lenovo:~/mydir/Hexo/source/_posts$ host baidu.com
baidu.com has address 123.125.114.144
baidu.com has address 111.13.101.208
baidu.com has address 220.181.57.217
baidu.com has address 180.149.132.47
baidu.com mail is handled by 20 jpmx.baidu.com.
baidu.com mail is handled by 20 mx1.baidu.com.
baidu.com mail is handled by 10 mx.n.shifen.com.
baidu.com mail is handled by 20 mx50.baidu.com.
```

如果想输出详细信息,即全部信息,可以用host -a baidu.com,输出和dig baidu.com一样,信息详细.

平常使用过程中使用最多的还是查询各种的消息记录,host查询各种消息类型用如下命令:
```
host -t ns baidu.com
charles@charles-Lenovo:~/mydir/Hexo/source/_posts$ host -t ns  baidu.com
baidu.com name server ns7.baidu.com.
baidu.com name server ns4.baidu.com.
baidu.com name server ns3.baidu.com.
baidu.com name server ns2.baidu.com.
baidu.com name server dns.baidu.com.
```
还有一个查询SOA权威域名服务器的选项:
```
charles@charles-Lenovo:~/mydir/Hexo/source/_posts$ host -C  baidu.com
Nameserver 220.181.38.10:
	baidu.com has SOA record dns.baidu.com. sa.baidu.com. 2012128552 300 300 2592000 7200
Nameserver 119.75.219.82:
	baidu.com has SOA record dns.baidu.com. sa.baidu.com. 2012128552 300 300 2592000 7200
Nameserver 202.108.22.220:
	baidu.com has SOA record dns.baidu.com. sa.baidu.com. 2012128552 300 300 2592000 7200
Nameserver 61.135.165.235:
	baidu.com has SOA record dns.baidu.com. sa.baidu.com. 2012128552 300 300 2592000 7200
Nameserver 220.181.37.10:
	baidu.com has SOA record dns.baidu.com. sa.baidu.com. 2012128552 300 300 2592000 7200
```

学习这三个命令,初级阶段主要了解了解基本用法即可,即查询域名的A,AAAA,NS,MX,PTR,SOA记录等等即可．

















