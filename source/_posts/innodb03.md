title: innodb_ruby工具使用
date: 2016-03-15 19:28:28
tags:
- innodb_ruby
- innodb
categories:
- innodb
toc: true

---

之前跟着Jeremy Cole的博客分析了单表空间的文件布局,这篇文章分析下如何使用innodb_ruby这个工具来分析.ibd表空间文件.

这个工具,可以自行到Jeremy Cole的github下载,他的github也有教如何安装使用.

# 分析一个最小空表格

----

我在MySQL5.7.11建立了一个只有一个主键的表,然后没有插入任何数据,也就是说是一个空表格.我们可以使用space-page-type-regions模式来查看这个表空间的初始页类型
```
# innodb_space -f /var/lib/mysql/test/t.ibd space-page-type-regions
start       end         count       type                
0           0           1           FSP_HDR             
1           1           1           IBUF_BITMAP         
2           2           1           INODE               
3           3           1           INDEX               
4           5           2           FREE (ALLOCATED)   
```
由这个输出可以看出,这个表分配了ibd文件的标准页:FSP_HDR,IBUF_BITMAP,INODE和空的root索引页.还有两个没有被使用的free页.

space-lists模式可以用来输出extent描述符和inode链表信息
```
# innodb_space -f /var/lib/mysql/test/t.ibd space-lists
name                length      f_page      f_offset    l_page      l_offset    
free                0           0           0           0           0           
free_frag           1           0           158         0           158         
full_frag           0           0           0           0           0           
full_inodes         0           0           0           0           0           
free_inodes         1           2           38          2           38  
```
初始化时,只有free_frag有extent描述符项,而且只有一个,即第一个extent,此时第一个extent为fragment extent,即该extent内的页是单独分配的.而且也只有一个INODE页.

free_frag里的内容可以使用space-list-iterate模式输出('#'表示页已被使用,'.'表示页是free)
```
# innodb_space -f /var/lib/mysql/test/t.ibd -L free_frag space-list-iterate
start_page  page_used_bitmap                                                
0           ####..               
```

所有索引段的内存信息可以使用space-indexes模式来输出;
```
# innodb_space -f /var/lib/mysql/test/t.ibd space-indexes
id          name                            root        fseg        used        allocated   fill_factor 
409                                         3           internal    1           1           100.00%     
409                                         3           leaf        0           0           0.00%     
```

因为只有一个主键索引,所以只有两个段internal和leaf.又因为是空数据库,所以只有一个空的root页,没有叶子节点页.

接下来可以使用index-fseg-internal-lists模式来输出主键索引的内部节点extent信息以及使用index-fseg-leaf-lists模式来输出主键索引叶子节点extent信息.
```
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-internal-lists
name                length      f_page      f_offset    l_page      l_offset    
free                0           0           0           0           0           
not_full            0           0           0           0           0           
full                0           0           0           0           0           
//-----------------------------------------------------------------------------
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-leaf-lists
name                length      f_page      f_offset    l_page      l_offset    
free                0           0           0           0           0           
not_full            0           0           0           0           0           
full                0           0           0           0           0     
```

因为是一个空表,所以任何链表都为空.那么有人可能会问,主键的root页在哪了?其实这root就是在frag page里面.因为每个段优先使用INODE entry优先使用32个frag page,这32个页全部使用之后,才会申请整个extent.

我们可以用index-fseg-internal-frag-pages模式来分析这个段零碎页的使用情况:
```
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-internal-frag-pages
page        index   level   data    free    records 
3           409     0       0       16252   0     
//------------------------------------------------------------------------------
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-leaf-frag-pages
page        index   level   data    free    records
```
由上述输出可以看出,内部索引段使用了一个零碎页,而叶子段没有使用任何一个页.

# 拥有一百万条记录的表

-----

接下来,我向之前的空表插入100万条记录,插入记录时必须用事务,而且等全部插入之后才commit,否则会很慢.

我们先来看下space-page-type-regions的输出
```
# innodb_space -f /var/lib/mysql/test/t.ibd space-page-type-regions
start       end         count       type                
0           0           1           FSP_HDR             
1           1           1           IBUF_BITMAP         
2           2           1           INODE               
3           37          35          INDEX               
38          63          26          FREE (ALLOCATED)    
64          1511        1448        INDEX               
1512        1663        152         FREE (ALLOCATED)   
```
我的这个输出和Jeremy Cole输出不一样,可能是5.7对底层页的使用进行了优化,没有那么多碎片.这100万条记录总共使用了35+1448个页;因为这个表的B+树有三层,一个root页,两个中间节点,其他都是叶子节点.所以对于内部节点段使用了3个零碎页,而叶子节点使用了32个零碎页,总共35个零碎页.剩下的26个页等需要时才会被使用.

我们再看下这个表空间的链表情况;
```
# innodb_space -f /var/lib/mysql/test/t.ibd space-lists
name                length      f_page      f_offset    l_page      l_offset    
free                2           0           1118        0           1158        
free_frag           1           0           158         0           158         
full_frag           0           0           0           0           0           
full_inodes         0           0           0           0           0           
free_inodes         1           2           38          2           38  
```
可以看到还是只使用了一个fragment extent,以及分配了两个free extent.可以用space-list-iterate来显示是哪两个extents被分配free
```
# innodb_space -f /var/lib/mysql/test/t.ibd -L free space-list-iterate
start_page  page_used_bitmap                                                
1536        ................................................................
1600        ................................................................
```
我们可以看到最后之前space-page-type-regions最后输出的两个extent是free,完全没有被使用.同时可以使用space-list-iterate来输出free-frag信息
```
# innodb_space -f /var/lib/mysql/test/t.ibd -L free_frag space-list-iterate
start_page  page_used_bitmap                                                
0           ######################################..........................
```

接下来,在来看下这两个段各自使用页信息:
```
# innodb_space -f /var/lib/mysql/test/t.ibd space-indexes
id          name                            root        fseg        used        allocated   fill_factor 
410                                         3           internal    3           3           100.00%     
410                                         3           leaf        1480        1504        98.40%      
```
可以看出来,内部节点有三个,即root页以及两个中间页.最后叶子节点页分配了1504个页,使用了1480个页.

因为内部节点段只使用了3个页,所以并没有分配任何的extent,而是只使用了3个零碎页
```
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-internal-lists
name                length      f_page      f_offset    l_page      l_offset    
free                0           0           0           0           0           
not_full            0           0           0           0           0           
full                0           0           0           0           0      
//-----------------------------------------------------------------------------------------------------------
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-internal-frag-pages
page        index   level   data    free    records 
3           410     2       26      16226   2       
36          410     1       7813    8139    601     
37          410     1       11427   4389    879     
```
可以看出root页在page 3,中间两个页分别在page 36和page 37. 两个中间节点的子节点即为叶子节点的数量601+879=1480,等于上述space-indexes的输出.

而叶子节点不仅使用了32个零碎页,还使用了22个extents和一个未满的extent,如下:
```
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 index-fseg-leaf-lists
name                length      f_page      f_offset    l_page      l_offset    
free                0           0           0           0           0           
not_full            1           0           1078        0           1078        
full                22          0           198         0           1038 
```

我们还可以迭代输出这三个链表的每一个,例如输出未满的链表:
```
# innodb_space -f /var/lib/mysql/test/t.ibd -p 3 -L not_full index-fseg-leaf-list-iterate
start_page  page_used_bitmap                                                
1472        ########################################........................
```

这里只是跟着Jeremy简单的使用innodb_ruby工具,还有一些使用方法,这里就没列出了,在我的github上也有一个简要的教程.自己亲自用innodb_ruby来输出ibd文件,可以加深对文件结构的理解记忆.

下篇文章将会分析ibd文件中,最重要的索引页结构,记着,在ibd文件中,存储索引和数据的页都是索引页.





















