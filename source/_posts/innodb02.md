title: innodb_ruby工具分析innob表空间文件Part-02
date: 2016-03-15 10:53:16
tags:
- innodb_ruby
- innodb
categories:
- innodb
toc: true

---

上篇文章分析了系统表空间和单独表空间的文件结构，这篇文章主要分析单独表空间各个页具体的结构，以及InnoDB是如何管理这些页，区和段信息．在看这篇文章之前，必须有上篇文章的基础，否则很难理解这篇文章．

# Extent和extent描述符

----

上篇文章有说到，一个表空间被被分成了一个个16KB的页，然后64个连续页(1MB)又分为一组．InnoDB在固定的位置分配FSP_HDR和XDES来跟踪extents的使用情况以及extents内部页的使用情况．这些页的结构如下图所示:
![FSP_HDR/XDES页结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-FSP_HDR%20Page%20Overview.png "")

该页有常规的FTL header和trailer，一个FSP header(这个后面分析)以及256个"extent 描述符".这个extent描述符保存了这个extent页的使用情况；每个XDES Entry结构如下所示；
![XDES Entry结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-XDES%20Entry.png "")

结构图中不同的域表示的意思如下:
1. File Segment ID: 表示这个extent属于那个段，例如主键内部节点段，主键叶子节点段等．
2. List node for XDES list: 因为所有的XDES是由双向链表串起来的，所以这个域保存了当前extent 描述符的前一个和后一个描述符指针；
3. State: 表示这个extent的状态，目前InnoDB只定义了4个状态值:FREE,FREE_FARG,FULL_FARG和FSEG．FREE表示这个extent还没使用，可以用于分配；FREE_FARG表示这个extent属于fragment，即碎片页，而且这个extent有可用的页，每个段一开始时会先从fragment分配32个零散页，32个零散页使用完毕之后，才会分配一整个extent；FULL_FRAG表示这个fragment以使用完毕，没有可用的页；FSEG表示这个extent已经被分配给某个段，有File Segment ID指示;
4. Page State Bitmap: 这个域用来指示extent内每个页使用情况；每一个页使用2位，那么64个页有128位，16字节．第一位表示这个页是否可free，第二个位预留用来表示这个页是否clean(has no un-flushed data)，但是目前这个还没有被使用，始终设为1

# List base nodes和list nodes

----

链表是一种连接多个相同数据类型的数据结构，为了适用于磁盘，InnoDB设计了如下链表数据类型:
![链表数据类型](http://7xjnip.com1.z0.glb.clouddn.com/ldw-List%20Base%20Nodes.png "")
这其实相当于链表的head节点，存储链表的长度，第一个节点和最后一个节点．这种base node一般是存储在高层的数据结构，真正的节点类型为
![链表节点类型](http://7xjnip.com1.z0.glb.clouddn.com/ldw-List%20Nodes.png "")
节点类型保存了上一个页节点的number和偏移量以及下一个页的number和偏移量．

因为接下来经常会看到链表和节点，所以这里就先稍微介绍下；

# 文件空间头和extent链表

----

FSP\_HDR页(page 0)除了保存了256个extent描述符之外，还有一个FSP header，这也是FSP_HDR和XDES页的区别．FSP header拥有好几个链表，用来保存extent,fragment以及inode的使用情况:
![FSP Header](http://7xjnip.com1.z0.glb.clouddn.com/ldw-FSP%20Header.png "")
非链表属性域解释如下:
1. Space id: 当前表空间的id
2. Highest page number in file(size): 当前表空间有效的最大page number，随着文件的增大而增大；这些页不一定全都初始化了，一些可能用0填充；
3. Highest page number initialized(free limit): 已经被初始化的最大页number，free limit永远小于等于上述size；
4. Flags: 这个表空间的一些标志；
5. Next Unused Segment ID:本表空间中下一个未使用的段ID．
5. Number of pages used in the FREE_FARG:这是一个优化，方便快速获取FREE_FRAG链表free页的数量，而不用去遍历链表；

图中的list节点解释如下:
1. FREE\_FRAG:这个链表存储的是有free页的fragment extent(作为fragment使用的extent)．fragment extent是按页来分配使用的，例如包含FSP\_HDR和XDES的extent将会被标记为fragment使用，之后如果有新建一个索引，那么这个索引段的32个碎片页就可以从这个FREE_FRAG链表中获取；
2. FULL_FRAG:这和FREE\_FRAG类似，也是存储fragment extent，但是FULL\_FRAG存储的是使用完毕，已经没有空闲页的fragment extent．如果在FREE\_FARG中的fragment extent使用完毕，没有空闲页之后，会被移到FULL\_FARG链表中；如果FULL\_FARG链表中的fragment extent不再使用时，将会被释放；
3. FREE:完全还没被使用的extent，也就是说这个extent可以被分配给段(file segment,放置在恰当的INODE链表中)，也可以被移到到FREE_FARG链表中，页单独分配使用；

FSP Header保存了一个表空间的最上层的元数据，即表空间可以使用的extents,可以的fragment extent,已满的fragment extent等等；当某个段(需要存储空间时)需要到FSP Header来分配可用的extents；

FSP Header保存的是整个extent的使用信息，而没有保存extent内部页的使用信息，因为每个extent描述符中有保存了该extent内部页的使用信息；

# 段(file segments)和inodes

----

我之前就是被file segment这个概念给弄糊涂了．人家就是个段，还一定要加个file,如果之前没看**InnoDB存储引擎**还真的没法参透这个概念.INODE Pages是一种页类型,这个页拥有许多的INODE项.每个INODE entries描述了一个段(FSEG).INODE pages的文件结构如下所示:
![INODE页结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-INODE%20Page%20Overview.png "")
每个页有85个INODE Entry,也就是可以保存85个段信息;所以一个INODE页最多可以保存42个索引信息(一个索引使用两个段).如果表空间有超过42个索引,则必须再分配一个INODE页.下面可以解释在FSP_HDR结构中出现的两个关于INODE的链表
1. FREE_INODES:一系列INODE页,这些INODE页至少有一个可用的INODE entry.
2. FULL\_INODES:一些列INODE页,这些INODE页所有INODE entry已使用;在独立表中的,只有表的索引超过42个,FULL_INODES才会有一个元素.

一个段INODE entry有如下格式:
![INODE Entry结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-INODE%20Entry.png "")
这个INODE entry非链表结构解释如下:
1. FSEG ID:这个INODE entry描述的段ID,如果这个entry没有被使用,那么这个ID值为0.
2. Magic Number:魔数,表示这个段INODE entry被正常初始化;
3. Number of used pages in the NOT\_FULL list:像FSP header中的FREE\_FRAG,作为一种优化,保存在链表NOT_NULL链表中页使用数量;
4. Fragment Array:大小为32的页数组,保存单独从fragment extent分配的页.如果数组32个页已经全部使用完毕,那么接下来就必须分配整个extent.

随着表的增长,段一开始现在fragment分配页,当32页满了之后,则必须转向分配整个extent

对于INODE entry中的链表结构,解释如下:

1. FREE:分配给这个段且完全没有被使用的extents
2. NOT\_FULL:分配给这个段的extent,且这个extent至少有一个页可以使用;如果这个extent全部页使用完毕,则这这个extent被移至FULL链表中.
3. FULL:这分配给这个段,且全部页都使用完毕的extent;如果有某个页变为可用,则被移至NOT_FULL链表中.

# 索引是如何使用段(file segments)

-----

虽然索引页还没介绍,我们这可以先来看下索引页是怎么使用file segments.每个root索引页FSEG header包含了这个索引使用INODE entries(用于描述file segments)的指针;每个索引有一个B+树叶子节点段和非叶子节点段.这些信息保存在INDEX页的FSEG header.
![FSEG Header结构](http://7xjnip.com1.z0.glb.clouddn.com/ldw-FSEG%20Header.png "")
Space id指向这个表空间的id,这个Page Number和Offset指向这个file segment的INODE entry.例如,一个新创建的表空间,唯一存在的索引页就是root页,也是一个叶子页.这个root存在于internal段,"leaf"段和fragment array暂时为空.

# 把所有整在一起

我们现在来看下单独表空间文件的整体布局:
![Index File Segment Structure](http://7xjnip.com1.z0.glb.clouddn.com/ldw-Index%20File%20Segment%20Structure.png "")

这个图很好展示了一个表空间的布局情况.我们从第四个页root页开始,在root页的FSEG Header中有保存着两个段leaf Inode(fseg\_id=2)和Internal Inode(fseg_id=3).这两个段指向了INODE页中各自的Inode entry.两个Inode entry都有一个frag array指向单独分配的零碎的页和若干个extents,由链表串起来.最后由extent描述符来跟踪extent内的页的使用情况.

总结下,这篇文章主要就是介绍了单个表空间几个主要页的结构信息以及各个页结构之间的关系.接下来,继续跟着Jeremy Cole来演示下innodb_ruby是如何使用的.





















































