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

deque底层实现相对vector和list更难.deque底层实现一个中控器,即一个指针数组,用于存储所有缓冲区的首地址.迭代器由四个部分组成cur|first|last|node:
1. cur指向缓冲区当前元素.
2. first指向缓冲区的第一个位置.
3. last指向末节点,即最后一个元素的下一个位置
4. node指向主控器相应的索引位置.

可以看下deque示意图,取自**STL源码剖析**
![deque示意图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_034.png "")

# deque 迭代器

-----------------------------------

deque迭代器也是一种Ramdon Access Iterator,但是它并不是普通指针,而是实现了迭代器+n式的移动.因为迭代器自增运算时,可能夸缓冲区,所以迭代器实现++运算时,还需判断是否跨缓冲区.

来看下迭代器:
```
template <class T, class Ref, class Ptr, size_t BufSiz>
struct __deque_iterator { 	// 未继承 std::iterator
  typedef __deque_iterator<T, T&, T*, BufSiz>      iterator;
  typedef __deque_iterator<T, const T&, const T*, BufSiz> const_iterator;
  static size_t buffer_size() {return __deque_buf_size(BufSiz, sizeof(T)); }
  typedef random_access_iterator_tag iterator_category; // (1)
  //因为为random_access_iterator,所以必须实现+n运算
  typedef T value_type; 				// (2)
  typedef Ptr pointer; 				// (3)
  typedef Ref reference; 				// (4)
  typedef size_t size_type;
  typedef ptrdiff_t difference_type; 	// (5)
  typedef T** map_pointer;//指向主控器的指针

  typedef __deque_iterator self;//泛型编程时,内部无需添加泛型参数

  // 以下四个就是一个迭代器对象的成员
  T* cur;	// 此迭代器所指之缓冲区的现行（current）元素
  T* first;	// 此迭代器所指之缓冲区的头
  T* last;	// 此迭代器所指之缓冲区的尾（含备用空间）
  map_pointer node;
```

以上就是跌迭代器内嵌型别和成员声明.关键是迭代器的类型random_access_iterator,以及四个成员变量.来看下迭代器的构造函数:

```
  //用一个T类型数据和指向主控器的指针来初始化一个迭代器
  __deque_iterator(T* x, map_pointer y) 
    : cur(x), first(*y), last(*y + buffer_size()), node(y) {}
  //创建一个空的迭代器
  __deque_iterator() : cur(0), first(0), last(0), node(0) {}
  //迭代器的复制构造函数
  __deque_iterator(const iterator& x)
    : cur(x.cur), first(x.first), last(x.last), node(x.node) {}
```
接下来看下迭代器各个重载运算算子:
```
  //迭代器解引用运算,返回迭代器目前指向的元素
  reference operator*() const { return *cur; }
  //重载指针运算符,返回当前元素的地址指针
  pointer operator->() const { return &(operator*()); }
  //返回两个迭代器的距离
  difference_type operator-(const self& x) const {
    return difference_type(buffer_size()) * (node - x.node - 1) +
      (cur - first) + (x.last - x.cur);
  }
```
第三个计算迭代器间的距离时,一定要注意不是简单的迭代器相减,因为迭代器间的距离是指两个迭代器间所有元素的个数,所以计算要把两个迭代器间所有数据都计算出来.

接下来是迭代器的一些++,--,+n,-n,==,!=重载运算,举几个例子:
```
self& operator++() {
    ++cur;				
    if (cur == last) {		
      set_node(node + 1);	
      cur = first;
    }
    return *this; 
  }
  self operator++(int)  {
    self tmp = *this;
    ++*this;
    return tmp;
  }
```
如果当前迭代器cur!=last,则直接++cur即可.如果++cur之后,cur==last,说明这是这个缓存区的最后一个元素,则这个迭代器要跳到下一个缓存区的第一个元素.第二个函数是后++式标准写法,返回++之前的元素.

```
 self& operator+=(difference_type n) {
    difference_type offset = n + (cur - first);
    if (offset >= 0 && offset < difference_type(buffer_size()))
      // 目标在同一个缓存区内,直接cur指针+n即可
      cur += n;
    else {
      // 目标位置不在同一个缓存区内
      difference_type node_offset =
        offset > 0 ? offset / difference_type(buffer_size())
                   : -difference_type((-offset - 1) / buffer_size()) - 1;
      // 切换至正确的节点）
      set_node(node + node_offset);
      // 切换到正确的元素
      cur = first + (offset - node_offset * difference_type(buffer_size()));
    }
    return *this;
  }
```

+=n运算关键是要判断+n之后的索引是否还在当前缓冲区内,如果在,cur简单+n即可.如果不在,则要计算正确的缓存节点和正确的元素位置.其他+n,-=n,-运算都可以通过+=运算得出.

还有三个迭代器等式运算:
```
reference operator[](difference_type n) const { return *(*this + n); }

  bool operator==(const self& x) const { return cur == x.cur; }
  bool operator!=(const self& x) const { return !(*this == x); }
  bool operator<(const self& x) const {
    return (node == x.node) ? (cur < x.cur) : (node < x.node);
  }
```
从[]号运算符的函数定义可以看出,[n]是相对于当前迭代器的位置.

# deque类

-----------

deque标准模板库有成员有一个主控器和两个迭代器,一个指向第一个缓冲区,一个指向最后一个缓冲区.定义如下:
```
 typedef pointer* map_pointer;	
  // 专属配置器,一次分配一个元素
  typedef simple_alloc<value_type, Alloc> data_allocator;
  // 专属配置器,一次分配一个指标大小
  typedef simple_alloc<pointer, Alloc> map_allocator;
  //获得缓存区的大小
  static size_type buffer_size() {
    return __deque_buf_size(BufSiz, sizeof(value_type));
  }
  static size_type initial_map_size() { return 8; }//默认map的大小,即指针个数

protected:                      
  iterator start;		// 表示第一个迭代器
  iterator finish;	// 表示最后一个迭代器

  map_pointer map;	// 指向主控器,即缓冲区的首地址指针数组
                          
  size_type map_size;	// map容纳指针的个数
```
## 默认构造函数
分析一个类,首先从构造函数开始,因为这是用户使用这个类的最开始的步骤.
```
  deque()
    : start(), finish(), map(0), map_size(0)
  {
    create_map_and_nodes(0);
  }
```
默认构造函数先初始化两个迭代器为空迭代器,然后map和map\_size为0,接着调用 create_map_and_nodes(size\_type num_elements)来初始化一块内存.如下:
1. 先根据num_elements来确定主控器节点的个数num_nodes,节点的个数是(初始化的8和num_nodes的最大值.
2. 调用map_allocator分配节点个数(初始化为8),并将指针赋值给map.
3. 然后设置nstart,nfinish为主控器中间节点(即第4个节点).
4. 然后为[nstart,nfinish]之间的节点分配缓冲区,即调用allocate_node.
5. 将first和finish设置为nstart和nfinish.
6. 设置start.cur和finish.cur

调用默认构造函数时,生成长度为8的缓冲区地址数组,然后start和finish指向第4个节点,并为第4个节点分配缓冲区.接下来就可以插入数据了.

## 由n个value初始化的构造函数

``` 
 deque(size_type n, const value_type& value)
    : start(), finish(), map(0), map_size(0)
  {
    fill_initialize(n, value);
  }
```
这个构造函数调用fill_initialize函数来初始化deque,在fill_initialize(size_type n,
const value\_type& value)函数中,
1. 先调用函数create\_map\_and\_nodes(n)分配好需要的缓冲区
2. 然后调用unitialized_fii来初始后缓冲区.

```
template <class T, class Alloc, size_t BufSize>
void deque<T, Alloc, BufSize>::fill_initialize(size_type n,
                                               const value_type& value) {
  create_map_and_nodes(n);	 // 先分配好缓冲区
  map_pointer cur;
  __STL_TRY {
    // 为每个节点的缓冲区设定初值
    for (cur = start.node; cur < finish.node; ++cur)
      uninitialized_fill(*cur, *cur + buffer_size(), value);
    // 最后一个节点区别对待,因为最后一个节点不一定满元素
    uninitialized_fill(finish.first, finish.cur, value);
  }
```
## 两队迭代器初始化的构造函数

较为典型,还有一种是用一对迭代器来初始化deque:
```
  template <class InputIterator>
  deque(InputIterator first, InputIterator last)
    : start(), finish(), map(0), map_size(0)
  {
    range_initialize(first, last, iterator_category(first));
  }
```
这个构造函数调用range_initialize来用迭代器范围内的元素初始化deque.range_initialize,根据迭代器类型,调用相应的版本,random_access_iterator调用的是如下版本:
```
template <class T, class Alloc, size_t BufSize>
template <class ForwardIterator>
void deque<T, Alloc, BufSize>::range_initialize(ForwardIterator first,
                                                ForwardIterator last,
                                                forward_iterator_tag) {
  size_type n = 0;
  distance(first, last, n);//n个元素
  create_map_and_nodes(n);//创建缓冲区空间
  __STL_TRY {
    uninitialized_copy(first, last, start);//初始化缓冲区
  }
```

# 析构函数

析构函数先是调用destroy函数析构缓冲区的数据,然后调用destroy_map_and_nodes函数析构缓冲区和主控器内存
```
  ~deque() {
    destroy(start, finish);
    destroy_map_and_nodes();
  }
```
# push_back和pop_back函数

以下是一些常用的函数,push_back,pop_back等等...
```
 void push_back(const value_type& t) {
    if (finish.cur != finish.last - 1) { 
      // 最后缓冲区还有大于等于1个元素空间
      construct(finish.cur, t);	// 直接在备用空间上赋值
      ++finish.cur;	// 调整最后一个缓存区的cur
    }
    else  // 最后缓冲区只有一个元素空间了
      push_back_aux(t);
  }
```
该当插入数据时,
1. 要先判断是否为最后一个缓冲区的最后一个空间,如果是,需要调用push_back_aux来插入数据.
2. 在push_back_aux函数中先要判断主控器是否还有空间,如果没有,则需要调用reserve_map_at_back()来重新开一块内存.
3. 在reserver_map_at_back函数内,将就map数据拷贝到新map,接着还需要把旧map回收了.
4. 为finish.node下一个节点分配缓冲区
5. 赋值,更新finish,指向下一个节点

```
template <class T, class Alloc, size_t BufSize>
void deque<T, Alloc, BufSize>::push_back_aux(const value_type& t) {
  value_type t_copy = t;
  reserve_map_at_back();		//符合某种条件必须换个map
  *(finish.node + 1) = allocate_node();	// 配置一个新节点
  __STL_TRY {
    construct(finish.cur, t_copy);		// 元素赋值
    finish.set_node(finish.node + 1);	// 改变finish,令其指向下一个节点
    finish.cur = finish.first;			// 设定finish状态
  }
  __STL_UNWIND(deallocate_node(*(finish.node + 1)));
}
```

接下来看下pop_back函数,即从尾部弹出一个元素;
```
  void pop_back() {
    if (finish.cur != finish.first) {
      // 最后一个缓冲区还有一个或更多的元素

      --finish.cur;		// 调整指标,相当于删除最后一个元素
      destroy(finish.cur);	// 将最后一个元素析构
    }
    else
      // 最后缓冲区没有元素
      pop_back_aux();		// 这里将进行释放缓冲区操作
  }
```
pop_back_aux函数中
1. 先是释放最后一个缓冲区的内存
2. 更新finish指标,指向前一个节点
3. 析构当前缓冲区最后一个元素

```
template <class T, class Alloc, size_t BufSize>
void deque<T, Alloc, BufSize>::pop_back_aux() {
  deallocate_node(finish.first);	// 释放最后一个缓冲区
  finish.set_node(finish.node - 1);	// 调整finish指标,使其指向
  finish.cur = finish.last - 1;		//  上一个缓冲区的最后一个元素
  destroy(finish.cur);				// 析构最后那个元素
}
```
还有push_front和pop_front函数,思想和push_back和pop_back思想一样,都要判断是否要跨越缓冲区,这里不做介绍.

# earse函数

```
iterator erase(iterator pos) {
    iterator next = pos;
    ++next;
    difference_type index = pos - start;	// 清除点之前的元素个数
    if (index < (size() >> 1)) {			// 如果清楚点之前的元素比较少，
      copy_backward(start, pos, next);	// 就搬移清除点之前的元素
      pop_front();				// 搬移完毕,删除最后一个元素
    }
    else {					// 清除点之后元素比较少
      copy(next, finish, pos);	// 就搬移清除点之后的元素
      pop_back();				// 搬移完毕,删除最后一个元素
    }
    return start + index;
  }
```
这个函数可能难看懂,主要是因为迭代器不是普通指针,所以看的时候,要考虑到迭代器的运算.还有个  iterator erase(iterator first, iterator last);函数思想类似...

# insert函数

最后再说下insert函数,insert函数有好几个版本,这里只介绍最简单的版本:
```
  iterator insert(iterator position, const value_type& x) {
    if (position.cur == start.cur) {	// 如果是安插在队列最前段
      push_front(x);				// 交给push_front 去做
      return start;
    }
    else if (position.cur == finish.cur) { // 如果安插点是deque 最尾端
      push_back(x);					  // 交给push_back 去做
      iterator tmp = finish;
      --tmp;
      return tmp;
    }
    else {
      return insert_aux(position, x);	 	// 交给 insert_aux 去做
    }
  }
```

接下来看下insert_aux,也是根据插入点前后元素个数比较来决定向前或向后移动.

```
template <class T, class Alloc, size_t BufSize>
typename deque<T, Alloc, BufSize>::iterator
deque<T, Alloc, BufSize>::insert_aux(iterator pos, const value_type& x) {
  difference_type index = pos - start;	// 安插点之前的元素个数
  value_type x_copy = x;
  if (index < size() / 2) {			// 如果安插点之前元素个数较少
    push_front(front());			// 在最前端加入与第一元素同值的元素。
    iterator front1 = start;		// 以下标识记号,然后搬移元素
    ++front1;
    iterator front2 = front1;
    ++front2;
    pos = start + index;
    iterator pos1 = pos;
    ++pos1;
    copy(front2, pos1, front1);		// 元素搬移
  }
  else {						// 安插点之后的元素个数比较少
    push_back(back());			// 在最尾端加入与最後元素同值的元素。
    iterator back1 = finish;	// 以下标识记号然后搬移元素...
    --back1;
    iterator back2 = back1;
    --back2;
    pos = start + index;
    copy_backward(pos, back2, back1);	// 元素搬移
  }
  *pos = x_copy;	// 在安插点设定新值
  return pos;
}
```

insert函数还有好几个版本
1. iterator insert(iterator position) { return insert(position, value_type()); }
2. void insert(iterator pos, size_type n, const value_type& x); 
3. void insert(iterator pos, int n, const value_type& x) {
    insert(pos, (size_type) n, x);
  }
4. void insert(iterator pos, long n, const value_type& x) {
    insert(pos, (size_type) n, x);
  }

5. void insert(iterator pos, InputIterator first, InputIterator last) {
    insert(pos, first, last, iterator_category(first));
  }
6. void insert(iterator pos, const value\_type* first, const value_type* last);
7. void insert(iterator pos, const\_iterator first, const_iterator last);

deque暂时说到这,基本用法大概都有说到了...





























