title: STL源码分析之list
date: 2015-10-28 19:13:23
tags:
- C/C++
- STL
- list
categories:
- STL

---
上篇文章分析了vector的实现原理，今天就来来看看list的源码实现。STL用环状双向链表来实现list，方法和leveldb的缓存环状链表一样，链表持有一个傀儡节点，不存储数据，只为这个链表的入口。迭代链表时，首先通过链表获得这个这个傀儡节点，然后通过next迭代所有数据。

STL将链表的傀儡节点作为链表的end节点，傀儡节点的next为begin节点，这样以来，就可以用[begin,end)这种左闭右开的形式来表示迭代器范围，和其他容器保持一致。

# list节点结构
```
template <class T>
struct __list_node {
  typedef void* void_pointer;
  void_pointer next;  // 为void*类型，其实可以是__list_node<T>*
  void_pointer prev;
  T data;//存储数据
};
```
因为是双向链表，所以有两个指针，分别指向前向指针和后向指针。

# 迭代器类型
因为list数据不是存储在连续的内存内，所以不能通过指针的加１减一来实现迭代器。list数据是通过指针链表结合在一起的，所以为了迭代所有数据，必须通过上个节点找到下个节点的地址，进而访问下个节点。list迭代器就是用这个原理，实现如下:
```
template<class T, class Ref, class Ptr>
struct __list_iterator {
 
  typedef __list_node<T>* link_type;

  link_type node;  // 这个迭代器指向的节点

  // 迭代器构造函数
  __list_iterator(link_type x) : node(x) {}
  __list_iterator() {}
  __list_iterator(const iterator& x) : node(x.node) {}

  // 迭代器必要的行为实现
  bool operator==(const self& x) const { return node == x.node; }
  bool operator!=(const self& x) const { return node != x.node; }
  //迭起器取值，取得是节点的值
  reference operator*() const { return (*node).data; }	

#ifndef __SGI_STL_NO_ARROW_OPERATOR
  //成员调用操作符
  pointer operator->() const { return &(operator*()); }
#endif /* __SGI_STL_NO_ARROW_OPERATOR */

  // 先加１，再返回，类似与++i
  self& operator++() { 
    node = (link_type)((*node).next);  	
    return *this;
  }
  //先加１，然后返回加１前的数据，类似与i++
  self operator++(int) { 
    self tmp = *this;
    ++*this;
    return tmp;
  }
  // 先减１，再返回，类似于--i
  self& operator--() { 
    node = (link_type)((*node).prev); 	
    return *this;
  }
  //先减１，再返回减１前的数据，类似于i--
  self operator--(int) { 
    self tmp = *this;
    --*this;
    return tmp;
  }
};
```
以上就是list的迭代器实现，只实现了迭代器的++,--，取值，成员调用四个基本操作，并没有像vector迭代器那样的+n操作，主要是因为地址不连续。

# list实现
接下来看下list实现，list只有一个成员变量，就是那个傀儡节点，也是end节点。

先来看构造函数:
```
  list() { empty_initialize(); } 
  void empty_initialize() { 
    node = get_node();	//创建一个节点，就是调用配置器分配内存 
    node->next = node;	//傀儡节点的前后都指向自己，形成一个环
    node->prev = node;　
  }
```
这个构造函数为默认构造函数，就是创建一个节点，然后前后指向自己而已。说到配置器，由于list用的是自己定义节点结构体，所以也定义了相应类型的配置器。
```
 typedef simple_alloc<list_node, Alloc> list_node_allocator;
```
list还定义几种构造函数，用n个值来初始化list，将另一个list的一部分数据来初始化list和复制构造函数。
```
  list(size_type n, const T& value) { fill_initialize(n, value); }
  list(int n, const T& value) { fill_initialize(n, value); }
  list(long n, const T& value) { fill_initialize(n, value); }
  explicit list(size_type n) { fill_initialize(n, T()); }
    list(const_iterator first, const_iterator last) {
    range_initialize(first, last);
  }
    list(const list<T, Alloc>& x) {
    range_initialize(x.begin(), x.end());
  }
```
这几个函数调用了fill_initialize和range_initialize，来看下这两个函数。
```
  void fill_initialize(size_type n, const T& value) {
    empty_initialize();
    __STL_TRY {
      insert(begin(), n, value);
    }
    __STL_UNWIND(clear(); put_node(node));
  }
   void range_initialize(InputIterator first, InputIterator last) {
    empty_initialize();
    __STL_TRY {
      insert(begin(), first, last);
    }
    __STL_UNWIND(clear(); put_node(node));
  }
```
这两个函数最后分别调用了insert函数的不同版本。一起来看下这两个insert函数。
```
template <class T, class Alloc>
void list<T, Alloc>::insert(iterator position, size_type n, const T& x) {
  for ( ; n > 0; --n)
    insert(position, x);
}
template <class T, class Alloc> template <class InputIterator>
void list<T, Alloc>::insert(iterator position,
                            InputIterator first, InputIterator last) {
  for ( ; first != last; ++first)
    insert(position, *first);
}
```
这两个函数通过循环调用 iterator insert(iterator position, const T& x) 这个insert版本，将数据一个一个插入到position之前，初始时就是插入到傀儡节点后面，形成初始链表，源码如下:
```
  iterator insert(iterator position, const T& x) {
    link_type tmp = create_node(x); //用x初始化构造一个节点
    // 将节点插入到position之前，更新前后关系
    tmp->next = position.node;
    tmp->prev = position.node->prev;
    (link_type(position.node->prev))->next = tmp;
    position.node->prev = tmp;
    return tmp;
  }
```
最后看下析构函数
```
  ~list() {
    clear();
    put_node(node);
  }
```
这两个函数，clear是清空链表所有数据，然后put_node是将傀儡节点回收了。

# 一些小函数
```
 iterator begin() { return (link_type)((*node).next); }
  const_iterator begin() const { return (link_type)((*node).next); }
  // begin函数返回的是傀儡节点的下一个节点
  iterator end() { return node; }	
    const_iterator end() const { return node; }
  reverse_iterator rbegin() { return reverse_iterator(end()); }
  const_reverse_iterator rbegin() const { 
    return const_reverse_iterator(end()); 
  }
  reverse_iterator rend() { return reverse_iterator(begin()); }
  const_reverse_iterator rend() const { 
    return const_reverse_iterator(begin());
  } 
  //当傀儡节点的下一个节点等于自己的时候，链表为空
  bool empty() const { return node->next == node; }
  //链表元素个数，通过调用distance函数求值
  size_type size() const {
    size_type result = 0;
    distance(begin(), end(), result);
    return result;
  }
  size_type max_size() const { return size_type(-1); }
  //链表最多能存储节点数
  reference front() { return *begin(); }  
  const_reference front() const { return *begin(); }
  // 取节点的内容，为引用。
  reference back() { return *(--end()); } 
  const_reference back() const { return *(--end()); }
  void swap(list<T, Alloc>& x) { __STD::swap(node, x.node); }
```
最后一个交换两个链表，只需要通过标准函数库的swap函数，交换两个傀儡节点即可，因为傀儡节点是每个链表的入口。

# 一些常用函数
1. 往链表前插一个元素，通过调用insert完成。
```
  void push_front(const T& x) { insert(begin(), x); }
```
2. 往链表尾巴插一个元素，也是通过insert函数完成。
```
 void push_back(const T& x) { insert(end(), x); }
```
3. 移除一个元素
```
  iterator erase(iterator position) {
    link_type next_node = link_type(position.node->next);
    link_type prev_node = link_type(position.node->prev);
    prev_node->next = next_node;
    next_node->prev = prev_node;
    destroy_node(position.node);
    return iterator(next_node);
  }
```
这个函数也很简单，只需要将被移除节点的前后节点跳过当前节点即可。
4. 前后删除一个节点，用erase函数实现:
```
  void pop_front() { erase(begin()); }//删除第一元素
  void pop_back() { 
    iterator tmp = end();
    erase(--tmp);//删除傀儡节点前一个元素
  }
```
# transfer函数
这个函数是很多list接口调用的函数。这个函数有点难看懂，我把《STL源码剖析》上的图截下来，容易理解:
![transfer函数示意图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_022.png "");

源码如下:
```
  //将[first,last)区间内的所有元素搬移到position之前
  void transfer(iterator position, iterator first, iterator last) {
    if (position != last) {
      (*(link_type((*last.node).prev))).next = position.node;	　　　　// (1)
      (*(link_type((*first.node).prev))).next = last.node;		// (2)
      (*(link_type((*position.node).prev))).next = first.node;  	// (3)
      link_type tmp = link_type((*position.node).prev);			// (4)
      (*position.node).prev = (*last.node).prev;			// (5)
      (*last.node).prev = (*first.node).prev; 				// (6)
      (*first.node).prev = tmp;						// (7)
    }
  }
```
按着序号来读那个示意图，应该能看懂，本质上就那几个关键节点的前后关系。

有了这个函数之后，就出现了一些很有用的函数:
```
  //将x链表的所有元素插入到当前list的position处
  void splice(iterator position, list& x) {
    if (!x.empty()) 
      transfer(position, x.begin(), x.end());
  }
  //将i处节点插到position之前，i和position可能来自同一个链表
  void splice(iterator position, list&, iterator i) {
    iterator j = i;
    ++j;
    if (position == i || position == j) return;
    transfer(position, i, j);
  }
  // 将[first,last) 內的所有元素结合于 position 所指位置之前。
  // position 和[first,last)可指向同一個list，
  // 但position不能位于[first,last)之內。
  void splice(iterator position, list&, iterator first, iterator last)  {
    if (first != last) 
      transfer(position, first, last);
  }
```
# remove函数
将数值为value的所有元素移除:
```
template <class T, class Alloc>
void list<T, Alloc>::remove(const T& value) {
  iterator first = begin();
  iterator last = end();
  while (first != last) {	// 通过前后节点来迭代所有节点
    iterator next = first;
    ++next;
    if (*first == value) erase(first); 	// 找到就移除
    first = next;
  }
}
```
# merge函数
合并两个链表，前提是两个链表必须有序，合并之后的链表也是有序的。merge之后，x链表被清空了。
```
template <class T, class Alloc>
void list<T, Alloc>::merge(list<T, Alloc>& x) {
  iterator first1 = begin();
  iterator last1 = end();
  iterator first2 = x.begin();
  iterator last2 = x.end();

  while (first1 != last1 && first2 != last2)
    if (*first2 < *first1) {
      iterator next = first2;
      transfer(first1, first2, ++next);
      first2 = next;
    }
    else
      ++first1;
  if (first2 != last2) transfer(last1, first2, last2);
}
```
# reverse函数
这个函数是用于将链表数据反序:
```
template <class T, class Alloc>
void list<T, Alloc>::reverse() {
  //如果元素个数为０或１，啥都不做
  if (node->next == node || link_type(node->next)->next == node) return;
  iterator first = begin();
  ++first;
  while (first != end()) {
    iterator old = first;
    ++first;
    transfer(begin(), old, first);//从链表begin开始，一个一个插入begin之前
  }
}    
```
这里要注意的是，在链表begin前插入元素，都将改变链表的begin。
# sort函数
list不能使用STL的sort算法，因为STL的sort算法必须接受RamdonAccessIterator，而sort的迭代器为Bidirectional iterators，所以list自己实现了这个sort算法:
```
template <class T, class Alloc>
void list<T, Alloc>::sort() {
  //元素个数为0或1时，啥都不做
  if (node->next == node || link_type(node->next)->next == node) return;

  // 一些新的list做临时存储
  list<T, Alloc> carry;
  list<T, Alloc> counter[64];
  int fill = 0;
  while (!empty()) {
    carry.splice(carry.begin(), *this, begin());
    int i = 0;
    while(i < fill && !counter[i].empty()) {
      counter[i].merge(carry);
      carry.swap(counter[i++]);
    }
    carry.swap(counter[i]);         
    if (i == fill) ++fill;
  } 

  for (int i = 1; i < fill; ++i) 
     counter[i].merge(counter[i-1]);
  swap(counter[fill-1]);
}
```
这个排序算法，本人看的也不是很懂，看了[鱼思故渊](http://m.blog.csdn.net/blog/yusiguyuan/38875429 "")的博客，略懂程序执行流程。大家可以看他的博客。

当然list还提供了带自定义比较的上述函数
```
  template <class Predicate> void remove_if(Predicate);
  template <class BinaryPredicate> void unique(BinaryPredicate);
  template <class StrictWeakOrdering> void merge(list&, StrictWeakOrdering);
  template <class StrictWeakOrdering> void sort(StrictWeakOrdering);
```

list大概就这些就这些了。

看STL源码真心可以学到东西，首先把基本数据结构复习了一遍，而且SGI里的数据结构比平时写的数据结构优秀多了。其次好好掌握了STL模板库用法。最后就是学到一些细节的东西，比如int(),double()表示这种类型的默认值。
