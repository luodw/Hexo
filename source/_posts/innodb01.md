title: innodb_ruby工具分析innodb表空间文件Part-01
date: 2016-03-14 20:35:32
tags:
- innodb
- innodb_ruby
categories:
- innodb

toc: true

---

一次偶然的机会进入一位谷歌工程师Jeremy Cole的博客[http://blog.jcole.us/innodb/](http://blog.jcole.us/innodb/ "")．该博客关于innodb一系列文章，我看之后获益匪浅，而且我第一次看时，由于不熟悉Jeremy的对变量的命名或者说是对innodb表空间文件的概念不是很熟，所以有点吃力，因此想通过博客记录下自己学习心得．

Jeremy自己开发了一个分析表空间的工具innodb_ruby(用ruby语言开发)，和**MySQL技术内幕　InnoDB存储引擎**中使用的py_innodb_page_info.py(用python语言开发)类似，主要是通过底层文件协议来解析表空间文件．Jeremy还上传了他用innodb_ruby解析表空间的各种图片示例．我将上述的两个开发工具和表空间的示例图上传到我的github上了，有需要可以到我github上下载[https://github.com/luodw/Innodb](https://github.com/luodw/Innodb "")

言归正传，接下来开始使用innodb_ruby工具以及配合Jeremy Cole博客来分析innodb表空间文件．

在MySQL5.5之前，所有数据默认是存储在共享表空间ibdata1中，但是可以通过innodb_file_per_table设置为每一个表一个文件．从MySQL5.6开始，已经默认使用一个表格一个表空间文件．我是更喜欢一表一文件形式，便于分析管理；

# 关于表空间的一些基础知识

----

之前在看**InnoDB存储引擎**时，了解到一个表空间文件是由一个一个16kb大小的页组成，然后64页，刚好是1MB组成一个区(extent)，然后由若干个区组成了段．也就是说一个表空间是分段管理的，假如有一个表只有一个主键索引，那么这个表就有两个段，一个是内部节点段，即非叶子节点段，还有一个是叶子段，即存储数据的节点．如果一个表除了主键索引，还有一个辅助索引，那么这个这个表空间有四个段，主键内部节点段，主键叶子节点段，辅助索引内部节点段，辅助索引叶子节点段．**InnoDB存储引擎**有有一张图很好展示了段，区，页的关系:
![InnoDB逻辑存储结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-%E9%80%89%E5%8C%BA_064.png "")

当然共享表空间ibdata和用户表空间是不一样的，因为它需要存储更多全局的一些信息，例如doublewrite,undo等等，所以共享表空间拥有更多的段，这篇文章先分析用户表空间．

每个表空间都有一个唯一space id，因为很多地方都需要使用到这个id，例如内存数据刷到磁盘时，需要使用这个space id来寻找表空间文件．InnoDB总有一个"系统空间"，即共享表空间，这个表系统表空间的space id始终为0．

# 页空间结构

-----

之前有说过，一个表空间文件被分为一个个16kb的页，每个页都有一个32位序号(page number)，通常称为偏移量，即离表空间初始位置的偏移量．因为每个页大小为16kb，所以第0个页的偏移量为0，第一个页的偏移量为16384等等．因为32位的最大值为2^32，所以一个表空间的最大值为2^32*16kb=64TB．

一个页的布局如下:
![InnoDB页布局](http://7xjnip.com1.z0.glb.clouddn.com/ldw-Basic%20Page%20Overview.png "")

每一个页都有一个38字节的FIL header和8字节的FIL trailer(FIL即为file缩写)，header结构有一个属性表明这个页是什么类型，而这个类型决定了页其他内容的结构，来看下FIL header和FIL trailer结构:
![FIL header和trailer结构图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-FIL%20Header%20and%20Trailer.png "")
1. Checksum为校验和，和磁盘打交道的程序为了保证数据正确性，都必须使用校验和，目的是验证因为磁盘空间损坏导致数据损坏；
2. offset(Page Number)为页的序号，即偏移量；
3. Previous Page和Next Page InnoDB的数据在内存缓冲区是由B+树组织的，而B+树中的每一层的页是由双向链表串起来，因为每个页header有指向上一个和下一个页的指针；这种结构可以提升全表扫描的效率；
4. LSN for last page modification　LSN如果不懂，可以查看**InnoDB存储引擎**这本书，简单说就是用于表示刷新到重做日志数据量，可用于重做日志恢复数据库.
5. Page Type 即页的类型，页的类型决定了这个页其他部分存储的数据，常见的页类型有数据业，undo页，系统页等等；
6. space id 即这个页属于的表空间
7. flush LSN 这个值存储了刷新到整个系统任何页的最大LSN值．


# 表空间结构

-----

一个表空间文件是由一系列的页组成的，页数量最多可达2^32个．为了更好管理页，页又按1MB(64个连续的页)分为组，这个组称为区，InnoDB一般情况下是按区来给段分配空间．

为了管理表空间所有页，区以及表空间自己，Innodb必须使用一些数据结构来跟踪保存页区等信息，下图展示了一个表空间的示意图:
![表空间文件示意图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-Space%20File%20Overview.png "")

每一个表空间的第一个页为FSP_HDR(file space header)页，这个页保存了FSP header结构，这个结构保存了这个表空间的大小，以及完全没有被使用的extents，fragment的使用情况，以及inode使用情况等等，后面再详细介绍．

第1个页只能保存256个extents，也就是16384个页，256MB．因此每隔16384个页必须分配一个页来保存接下来的16384个页的信息，这个页就是XDES页，这个XDES页和第１个页除了FSP_HDR结构置0外，其他都一样．IBUF_BITMAP这个页就是插入缓存bitmap页，用于记录插入缓冲区的一些信息．

第三个页是inode页，该页用一个链表存储表空间中所有段(file segments)；之前说段是由若干个extents组成，其实段除了extents之外，还有32个单独分配的"碎片"页组成，因为有些段可能用不到一个区，所以这里主要是为了节省空间．

# 共享表空间

-----

共享表空间space id为0，包含了很多分配在固定偏移量上的页，用来存储和InnoDB操作相关的大量信息．系统表空间和其他空间一样，也有FSP_HDR,IBUF_BITMAP和INODE页，并且分配在前三个页，但是第四个页之后，和独立表空间就不太一样了
![共享表空间结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-ibdata1%20File%20Overview.png "")
下面是分配的页:
1. Page 3，type SYS:保存和插入缓存相关的信息
2. Page 4,type INDEX:插入缓存的索引结构的root页，插入缓存也是一个B+树；
3. Page 5,type TRX_SYS: 记录和InnoDB事务操作相关的信息，例如最近一次的事务id,MySQL二进制日志信息以及两次写缓冲区的位置信息；
4. Page 6,type SYS: 第一个回滚段(rollback segment)页，回滚段例外的页或者整个区当需要的时候才会被分配出来存储回滚段信息；
5. Page 7,type SYS: 存储和数据字典相关的信息，包含了数据字典中所有表格root页面的个数．当我们要访问数据字典表页时，就需要这些信息．
6. Pages 64-127: 第一个double write buffer页块（64块，即一个extent）．double write buffer是InnoDB的一个恢复机制；
7. Pages 128-191:double write buffer的第二个页块．

系统表空间其他页则在索引，回滚段和undo logs等等需要时分配．

# 单独表空间

----

这篇文章的最后一部分就是单独表空间．从MySQL5.6开始，默认就是一个表，一个表空间文件．以.ibd后缀的文件就是单独表空间文件，有如下结构
![独立表空间](http://7xjnip.com1.z0.glb.clouddn.com/ldw-IBD%20File%20Overview.png "")

单独表空间文件结构很简单，没有共享表空间存储数据类型种类多；前三个页分别是FSP_HDR,IBUF_BITMAP和INODE页，从第四个页开始存储索引页．在InnoDB中，B+树内部节点页和叶子节点页统称为索引页(index pages)．第四个页固定为主键的root页，其他页则可能是内部节点页，主键叶子节点，辅助索引root页，辅助索引内部节点页和辅助索引叶子节点页．

因为大部分InnoDB系统信息都保存在共享表空间中，所以单独表空间(per-table space)大部分都是type INDEX页保存表数据．

熟悉表空间的文件结构对于理解InnoDB缓冲区中的B+树很有帮助，第一次看MySQL B+结构时，我就没搞清楚叶子节点是怎么存储单条数据的（其实是一个页的数据）．后来看了**InnoDB存储引擎**才知道原来叶子节点保存的是记录集合，记录由单链表连在一起，查找到页之后，还需通过页目录定位到一部分数据，最后再便利这一小部分数据找到所需的数据．

这篇文章先大概介绍下单独表空间和系统表空间结构，接下来跟着大神Jeremy Cole的脚步，我们来分析下单独表空间具体页的结构信息．

感谢Jeremy Cole[http://blog.jcole.us/innodb/](http://blog.jcole.us/innodb/ "")























