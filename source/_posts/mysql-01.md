title: MySQL一些基础知识
date: 2016-03-04 21:42:59
tags:
- MySQL
- innodb
categories:
- MySQL
toc: ture

---

最近在深入学习MySQL存储引擎innodb,使用书籍为**MySQL技术内幕(InnoDB存储引擎)**第二版;在学习过程中,由于有之前看NoSQL数据库的基础,学习比较快,但是也发现了一个问题,即show环境变量,到底什么时候是会话变量,什么时候是全局变量,以及'select+函数'怎么用等等;很多都是基础问题,虽然会用,但是总是迷迷糊糊,所以打算通过这篇文章记录下来,今后查找,也方便;

首先一开始,先介绍MySQL数据库的变量.MySQL数据库有四种变量,会话范围内的系统变量,全局范围内的系统变量,用户自定义变量和局部变量;

# 变量

在**MySQL技术内幕(InnoDB存储引擎)**这本书中,好多地方用到show variables like'pattern'\G;来查看系统变量,MySQL提供两种方法来设置系统变量.

第一种方法,使用set和select
```
设置系统变量:
set @@[session|global].变量名=值;  默认(没有指明session或者global)为session
例如: set @@session.sort_buffer_size=4000;

显示系统变量:
select @@[session|global].变量名  默认为session
例如: select @@session.sort_buffer_size\G;
```

第二种方法,使用set和show,推荐使用这种方法,因为经常记不住变量名时,可以使用show来模糊查找变量名
```
设置系统变量:
set [session|global] 变量名=值  默认为session
例如: set session sort_buffer_size=4000;

显示系统变量:
show [session|global] variables like 'pattern';
例如: show session variables like 'sort_buffer_size'\G;
```

用户变量:即用户在MySQL客户端设置的变量,只有在当前连接有效,如果客户端重新连接,则之前设置的用户变量全部失效;可以如下设置用户变量:
```
设置用户变量:
set @变量名=值   或者select @变量名:=值
例如: set @name='jason';  或者select @name:='jason';
显示用户变量:
select @变量名
例如: select @name\G;
```

局部变量即为在存储过程,函数或者触发器begin和end声明的变量,例如:
```
begin 
    delcare name varchar(30) default 'hello world';
end
```

# select和show使用情况

第二个经常碰到的基础知识是select和show的使用,因为这两个在MySQL使用比较频繁,所以这里总结下使用情况:

一般使用show的情况是
1. 显示系统变量,正如上述所说
2. 显示系统资源,例如
```
show databases\G;
show tables\G;
show triggers\G;
show processlist\G;
show procedure status\G;
show function status\G;
....等等
```

一般使用select的情况是
1. 显示系统和用户变量,如上述所说
2. 用在查询语句中
3. 后接函数,执行函数,经常使用的函数有:
```
select database()\G;//显示当前使用的数据库
select connection_id()\G;//显示当前连接id
select user();/select system_user(); //显示当前的登陆用户
select version();//显示当前MySQL的版本
如果是显示innodb的版本,可以使用
select @@innodb_version
```


以上是我最近在使用过程中的一些基础知识总结,后续有,再补充...




















-
