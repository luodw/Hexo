title: STL源码分析之deque
date: 2015-11-04 22:25:01
tags:
- STL
- deque
categories:
- STL
toc: true

---

在C++标准模板库序列式容器中,使用最少的估计就是deque,因为平常使用最多的就是用一个可增长的空间来保存数据,而vector,list几乎都可以实现这些功能,所以就很少使用deque如何使用.但是deque这种双端队列,特别是了解这种数据结构的底层实现是很有帮助的.stack和queue这两种容器,不对,正确叫法应该是容器适配器,因为这两种容器底层是调用其他容器,他俩只是提供先进后出和先进先出的接口而已.这两种容器底层实现默认就是用deque.

deque底层实现相对vector和list更难.dequeue底层实现一个中控器,即一个指针数组,用于存储所有缓冲区的收首地址.迭代器由四个部分组成cur|first|last|node:
1. cur指向缓冲区当前元素,即下一个元素存储位置.
2. first指向缓冲区的第一个位置.
3. last指向末节点,即最后一个元素的下一个位置
4. node指向主控器相应的索引位置.

可以看下deque示意图,取自**STL源码剖析**
![deque示意图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_034.png "")


