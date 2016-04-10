title: innodb索引页index的物理格式
date: 2016-03-17 16:57:43
tags:
- index
- innodb
categories:
- innodb
toc: true

---
今天跟着Jeremy Cole的博客,继续学习innodb底层数据文件索引页的物理格式.理解innodb的索引物理页格式对理解内存中的B+树很有帮助,因为innodb一次就是将整个页载入内存并且插入二叉树中.

接下来,先理解Jeremy在博客中说的,"Everything is an index in InnoDB",什么意思了?最简单的理解就是innodb的B+树索引是聚簇索引,即叶子节点是和内部索引节点一样,按B+的插入顺序组织.所以可以理解为整棵树节点都是索引节点.Jeremy解释如下:
1. 每个表格都有一个主键:如果CREATE TABLE时没有指定一个,那么第一个非空的唯一键将会被选为主键.如果没有非空的唯一键,那么一个48位的"Row ID"域将会自定添加到表结构作为主键.所以最好每次在创建表格时,自己创建一个主键,因为系统添加的索引对我们是无用的而且还浪费6个字节.
2. "row data"(非主键域)的数据也是存储主键索引结构中,

































