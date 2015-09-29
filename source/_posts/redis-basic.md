title: redis安装与运行
date: 2015-09-23 14:53:32
tags:
- Redis
categories:
- Redis
    
toc: true

---
　　Redis是一个key-value存储系统，即键值对非关系型数据库，和Memcached类似，目前正在被越来越多的互联网公司采用。本教程只是简易的教程，指导大家如何安装运行Redis以及简单地操作Redis。如果要深入学习Redis，可以参考文章末尾的链接。

<!--more-->

　　Redis支持存储的value类型包括string(字符串)、list(链表)、set(集合)和zset(有序集 合)。这些数据类型都支持push/pop、add/remove及取交集并集和差集及更丰富的操作，而且这些操作都是原子性的。在此基础上，Redis支持各种不同方式的排序。与memcached一样，为了保证效率，数据都是缓存在内存中。区别的是Redis会周期性的把更新的数据写入磁盘或者把修改操作写入追加的记录文件，并且在此基础上实现了master-slave(主从)同步。

　　Redis 是一个高性能的key-value数据库。 redis的出现，很大程度补偿了memcached这类keyvalue存储的不足，在部 分场合可以对关系数据库起到很好的补充作用。它提供了Python，Ruby，Erlang，PHP客户端，使用很方便。


## Redis安装

　　首先，从网站  <https://github.com/dmajkic/redis/downloads>  下载Redis最新版本2.4.5，然后解压至计算机某个磁盘中即可。接着运行两个Doc窗口，一个用户Redis服务器，一个用于Redis客户端。两个Doc窗口都进入Redis数据库根目录，服务器窗口在根目录下输入redis-server redis.conf即可运行Redis服务器，如图7.2.1所示 

![图7.2.1 启动Redis服务器](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/redis-server.png "")

　　客户端在根目录下输入redis-cli，即可运行Redis客户端，如图7.2.2所示

![图7.2.2启动Redis客户端](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/redis-cli.png "")

　　此时，服务器端显示接受一个客户端，显示为IP地址：端口，如图7.2.3所示

![图7.2.3 Redis显示接受一个客户端](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/QQ截图20150913220408.png "")

　　至此，Redis运行成功，接下来，即可操作Redis存取数据。

## Redis实例演示

本实验用的数据为如下三个表格：

学生表格： 

![学生表格](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/QQ图片20150922203728.png "")

课程表格：

![课程表格](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/QQ图片20150922203801.png "")

成绩表格：

![成绩表格](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/QQ图片20150922203733.png "")

　　本部分实验的数据如上，必须先把数据存入Redis。关系数据库转化为KV键值数据库，并不是简单的set key value，因为表格之间存在着关系，所以我们采用如下方法：
　　　　　　　　　　　　　　　　　　　Key=表名：主键值：列名
　　　　　　　　　　　　　　　　　　　　　Value=列值
例如，对于之前数据的存入，可以按如图7.2.4方式存入：

![图7.2.4 Redis实例数据库插入](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/实例截图2.png "")

　　针对之前存入的数据，我们在这简单地演示Redis的增删改查。Redis支持5中数据类型，不同数据类型，增删改查可能不同，这里用最简单的数据类型字符串作为演示。  
  
### Redis插入数据

　　Redis插入一条数据，只需要先设计好键值，然后用set命令存入即可。例如在课程表插入新的课程算法，4学分，所以可输入set Course:8:Cname 算法和set Course:8:Ccredit 4，如图7.2.5所示;    

![图7.2.5 Redis插入数据](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/insert.png "")

### Redis修改数据

　　Redis并没有修改数据的命令，所以如果在Redis中要修改一条数据，只能在使用set命令时，使用同样的键值，然后用新的value值来覆盖旧的数据。例如修改新添加的课程，名字改为编译原理，则图7.2.6所示：
    
![图7.2.6 Redis修改数据](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/update.png "")

　　先调用get命令，输出原先的值，然后set新的值，最后再get得到新值，所以修改成功。    

### Redis删除数据

　　Redis有专门删除数据的命令del，用法为del key值即可。所以如果要删除之前新增的课程编译原理，只需输入命令del Course:8:Cname，同时还应该把本课程的学分删除del Course:8:Ccredit，如图7.2.7所示;

![图7.2.7 Redis删除数据](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/delete.png "")

　　当输入del Course:8:Cname时，返回1，说明成功操作一条数据。当再次输入get命令时，输出为空，说明删除成功。    

### Redis查询数据

　　Redis最简单的查询方式为用get命令，之前的图例已有展示。如果要进行关系数据库表格连接查询，则需要进行多步查询，这时要先将(姓名，学号)和(课程名，课程号)键值对存储数据库，用于后续查询，如图7.2.8所示：

![图7.2.8 Redis简单查询](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/QQ截图20150914171515.png "")

　　这时，如果要查询李勇的数学分数，在关系数据库中需要连接3个表，Redis的做法为

①输入命令：get 李勇  获得李勇的学号；
②输入命令：get 数学  获得数学的课程号；
③获得李勇学号和数学的课程号之后，在输入命令get SC:学号:课程号:Grade 即可得到李勇的分数，如图7.2.9所示：

![图7.2.9 Redis复杂查询](http://dblab.xmu.edu.cn/blog/wp-content/uploads/2015/09/QQ截图20150914172043.png "")

　　本文只是初步介绍Redis的安装与运行，如果想深入学习Redis,可以点击以下链接查看：

　　* Redis中文官方网站 <http://www.redis.cn/> ，含有Redis简介以及Redis客户端和Redis命令的详细介绍，是学习Redis的好地方。
　　* 这篇博客 <http://blog.csdn.net/eroswang/article/details/7080412> 简要介绍了Redis以及Redis命令的使用，容易上手。
