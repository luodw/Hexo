title: leveldb源码分析之sst文件格式
date: 2015-10-21 19:54:36
tags:
- leveldb
- sst
- block
- filterpolicy
categories:
- leveldb

---

之前leveldb分析，讲解了leveldb两大组件memtable和log文件。这篇文章主要分析leveldb将内存数据写入磁盘文件，这些磁盘文件的格式，下一篇文章再分析源码。

leveldb插入数据时，首先将数据插入memtable，当memtable数据量达到一定大小时，当前memtable赋值给immemtable（也是memtable类型，但是这个是只读的），然后产生一个新的memtable用于后续的数据插入，immemtable将会把数据持久化到磁盘中。

磁盘文件是按分level的，immemtable首先将数据compaction到level0文件中，称为minor compaction。所以level0之间可能存在数据重叠。当某个level i文件达到一定数量时，选择一个文件与level i+1合并，称为major　compaction。可以再看下leveldb模型图：

![leveldb模型图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-1360076329_9985.JPG "")

# sst文件格式
leveldb将sst文件切割成一个一个块，每个块都是有数据＋类型＋CRC码，所以每个sst文件打开格式都是如下图所示：
![sst文件格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--sst文件布局1.jpg "")

leveldb根据用途将这些block又分为数据块，元数据块，元数据块索引块，数据块索引块和文件尾。
1. 数据块主要就是存储数据的地方，immemtable中的键值对就是存储在数据块；
2. 元数据块主要就是用于过滤，加快检索速度。
3. 元数据块索引块，leveldb默认一个过滤器，所以元数据块索引块就一条记录；
4. 数据块索引块，存储每一个数据块的偏移和大小，用于定位索引块。
5. 文件尾，存储了数据块索引块和元数据块索引块，用于读取这两个块；
模型图如下：

![sst文件具体格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--sst文件布局2.jpg "")

例如要读取某个data block，可以先读取出footer，然后读取出index block,由于index block中存储各个数据块的偏移和大小，就可以读取出这个data block。

接下来，将分别介绍各种块的格式。
# data block格式
首先介绍的是数据块的格式，模型图如下：

![data block格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Block.jpg "")

数据块上部分主要存储的是一条条的记录，记录的格式如下：

![sst记录格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--记录格式.jpg "")

每一条记录有key共享长度＋key非共享长度＋value长度＋key非共享内容+value内容组成。leveldb为了节约存储，并不是存储每一条记录键值的完整值，而是两条记录如果有共享的部分，那么第二条记录可以和第一条共享共享的部分。例如第一条记录为hello world:11，第二条记录为hello you:9，那么第一条记录存储格式为:0+11+2+hello world+11，首先说明下，第一条记录共享长度为0，因为它没有上条记录，所以就没有共享。那么第二条记录存储格式为：6+3+1+you+9。

数据块Restart[i]表示一个共享记录的开始，这条记录和第一条记录一样，共享长度为０，Restart[i]存储就是这个共享记录的偏移。

数据块的最后一个部分为Restart点的个数，图中为3个。

# Meta block格式
Meta block存储主要是过滤器的内容，先给出模型图如下：
![Meta block格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Filter.jpg "")

Filter i存储的是这个每个数据块的键值，当要读取i数据块时，可以先到Filter i查找键值，如果没有找到，就没必要读取这个块了。因为filter比data块小，读取IO消耗更小。Filter i 偏移表示Filter i在Meta block的偏移量，偏移数组的位置就是第一个Filter 1 偏移的地址，最后g(base）用于决定数据量多大时，创建一个Filter。


# 索引块的格式
## Meta block格式
Meta block格式相对简单，因为leveldb默认只有一个过滤器，当然用户可以自己定义过滤器。格式如下：
![Meta block格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Metaindex.jpg "")

其中，key＝"filter."+过滤器名字。后面两个字段表示Meta block块的在文件的偏移量和大小，方便读取。

## index block格式
index block格式如下：
![index block格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--数据索引1.jpg ""
)
第一个字段存储第i块最大的键值，但是必须比第i+1个data block最小键值小。因为block数据是有序的（skiplist数据为有序），所以有最大键值，就可以知道这个块存储的数据的键值范围。第二个和第三个字段分别表示第i个data block的偏移量和大小，方便读取。

例如第i个data block最小键值为hello，最大键值为world；第i+1个data block最小键值为www，最大键值为yellow，所以第i个data block的键值字段为world。

# Footer格式
sst文件最后一部分为Footer，格式如下：
![Footer格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Footer.jpg "")
前两个存储Metaindex块的偏移量和大小以及Index块的偏移量和大小。也是为了后续读取方便。Padding填充部分，Magic number魔数，用于验证正确性。

sst文件格式大概就如上所示，下一篇文章，分下源码。








