title: leveldb安装和使用
date: 2015-10-14 21:00:01
tags:
- leveldb
categories:
- leveldb

---

我研一时就给自己定义了学习路线，系统->语言->开源框架。研一的时候，我学习了linux系统命令，系统调用，内核一些原理，研二刚看了C++对象模型，所以接下来我要学习下leveldb源码。研一暑假时，我看了redis源码，这个leveldb源码分析结束之后，再把那个整理下发上来。

分析开源优秀框架的源码是非常有价值，有意义的。
1. 首先分了某个框架，那么你就对这个框架从底层上的了解。
2. 其次，可以了解到某个语言是怎么用的。我看了leveldb，某种目的上，就是想看看C++面向对象是怎么使用的。因为平时，我们都是用C++面向过程的部分。
3. 最后，学习优秀框架架构，以及框架里面很多细节知识。例如redis里面就嵌入一个io多路复用框架ae。

这篇文章首先介绍下leveldb是如何安装以及简单使用，接来的文章，就介绍下leveldb源码解析。

## leveldb安装
首先可以从<https://github.com/google/leveldb.git>下载leveldb，然后cd到leveldb目录中，执行
```
make
```
过一会，就可以在目录下看到静态链接库libleveldb.a和动态链接库libleveldb.so.1.18.
如果不用动态链接库的话，安装已经完成了。但是如果要用动态链接库，则还需要把头文件以及动态链接库拷贝到系统路径里面，具体如下：
1. 把include/leveldb目录拷贝到/usr/include
```
sudo cp -r include/leveldb /usr/include
```
2. 把动态链接库文件拷贝到/usr/lib下，再按当前目录下的形式，创建两个软连接。
```
sudo cp libleveldb.so.1.18 /usr/lib
cd /usr/lib
sudo ln -s libleveldb.so.1.18 libleveldb.so.1
sudo ln -s libleveldb.so.1 libleveldb.so
ldconfig
```
最后要执行ldconfig命令，将动态链接库加到缓存中，这样系统才能真正使用这个动态链接库。我在之前一篇文章有说<http://luodw.github.io/2015/09/25/config/#more>

自此，leveldb就算安装好了。

## leveldb入门程序
接下来，我用一个小程序来介绍下leveldb使用方法。
```
#include <iostream>
#include <cassert>
#include <cstdlib>
#include <string>
#include <leveldb/db.h>
using namespace std;
int main(void)
{
	leveldb::DB *db;
	leveldb::Options options;
	options.create_if_missing=true;
	leveldb::Status status = leveldb::DB::Open(options,"./testdb",&db);
	assert(status.ok());
	std::string key1="people";
	std::string value1="jason";
	std::string value;
	leveldb::Status s=db->Put(leveldb::WriteOptions(),key1,value1);
	if(s.ok())
		s=db->Get(leveldb::ReadOptions(),"people",&value);
	if(s.ok())
		cout<<value<<endl;
	else
		cout<<s.ToString()<<endl;
	delete db;
	return 0;
}
```
该程序很简单，就是插入一条键值对，接着取出这个键值对。

静态链接库如下编译，静态链接库必须在当前目录下，或者指出库的绝对路径
```
 g++ mytest.cc -o mytest ./libleveldb.a -lpthread
```
动态链接库编译如下，动态链接库不需要在当前文件下，系统能自动到相关路径下查找，所以动态链接库相对静态链接库相对方便些。
```
g++ mytest.cc -o mytest -lpthread -lleveldb
```
一定要加-lpthread，因为leveldb有用到线程相关调用。

最后运行结果如下：
```
jason
```
据我了解，leveldb无外乎就是键值对的插入，查询，有迭代器全局查询，还有快照和批量操作。待我深入学习之后，在分享出来。



