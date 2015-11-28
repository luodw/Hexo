title: STL分析之map和set
date: 2015-11-19 20:12:06
tags:
- rb_tree
- STL
- set
- map
categories:
- STL

---
之前分析二叉搜索树和平衡二叉树时，真心感觉树的实现真是难，特别是平衡二叉树，不平衡之后需要调整，还要考虑各种情况，累感不爱．今天看到这个红黑树，发现比平衡二叉树还难，但是红黑树比平衡二叉树使用的场景更多，所以平常使用时，我们需要了解红黑树的实现原理，如果有能力，可以自己实现，但是如果实在做不出来，也没关系，因为STL和linux内核都有现成的红黑树实现，拿来用即可，前提是了解红黑树原理．

# 红黑树原理

----

红黑树和平衡二叉树一样，本质上都是二叉搜索树，但是二者的搜索效率都能实现平均效率logn，比二叉搜索树性能好．平衡二叉树实现原理是判断每个节点的左右子树的高度差是否等于2，如果等于2，则要通过旋转来实现树的左右子树高度差平衡．而红黑树实现原理是节点的颜色和旋转来实现的，实现较复杂，先看下红黑树的满足条件:
1. 每个结点要么是红的，要么是黑的。
2. 根结点是黑的。
3. 每个叶结点，即空结点（NIL）是黑的。
4. 如果一个结点是红的，那么它的俩个儿子都是黑的。
5. 对每个结点，从该结点到其子孙结点的所有路径上包含相同数目的黑结点。
如果某棵二叉搜索树满足上述条件，则为红黑树．为什么满足上述条件可以实现平衡了？主要是第４条和第５条，由第５条可以得出，某个到所有叶子节点最长路径是最短路径的两倍.即一条路径为一黑一红和一条路径为全黑,大体上红黑树是平衡的,只是没有AVL树要求那么严格.

我不推荐直接看STL源码剖析这本书中的红黑树,而是先到网上博客先看看大家是怎么写,因为这本书STL实现的红黑树比较复杂,不好看懂.我推荐博客[michael](http://blog.chinaunix.net/uid-26575352-id-3061918.html ""),因为这篇博客一步一步讲解很好,图做的也很好理解.

# 红黑树节点和迭代器

----


红黑树节点和迭代器的设计和slist原理一样,将结构和数据分离.原理如下:
```
struct __rb_tree_node_base
{
  typedef __rb_tree_color_type color_type;
  typedef __rb_tree_node_base* base_ptr;

  color_type color; 	// 红黑树的颜色
  base_ptr parent;  	// 父节点
  base_ptr left;	  	// 指左节点
  base_ptr right;   	// 指向右节点
}
template <class Value>
struct __rb_tree_node : public __rb_tree_node_base
{
  typedef __rb_tree_node<Value>* link_type;
  Value value_field;	// 存储数据
};
```
红黑树的基础迭代器为struct \_\_rb_tree_base_iterator,主要成员就是一个\_\_rb_tree_node_base节点,指向树中某个节点,作为迭代器与树的连接关系,还有两个方法,用于将当前迭代器指向前一个节点decrement()和下一个节点increment().下面看下正式迭代器的源码:```
template <class Value, class Ref, class Ptr>
struct __rb_tree_iterator : public __rb_tree_base_iterator
{
  typedef Value value_type;
  typedef Ref reference;
  typedef Ptr pointer;
  typedef __rb_tree_iterator<Value, Value&, Value*>     iterator;
  typedef __rb_tree_iterator<Value, const Value&, const Value*> const_iterator;
  typedef __rb_tree_iterator<Value, Ref, Ptr>   self;
  typedef __rb_tree_node<Value>* link_type;

  __rb_tree_iterator() {}//迭代器默认构造函数
  __rb_tree_iterator(link_type x) { node = x; }//由一个节点来初始化迭代器
  __rb_tree_iterator(const iterator& it) { node = it.node; }//迭代器复制构造函数


  //迭代器解引用,即返回这个节点存储的数值
  reference operator*() const { return link_type(node)->value_field; }
#ifndef __SGI_STL_NO_ARROW_OPERATOR
  //返回这个节点数值值域的指针
  pointer operator->() const { return &(operator*()); }
#endif /* __SGI_STL_NO_ARROW_OPERATOR */
  //迭代器++运算
  self& operator++() { increment(); return *this; }
  self operator++(int) {
    self tmp = *this;
    increment();
    return tmp;
  }
  //迭代器--运算
  self& operator--() { decrement(); return *this; }
  self operator--(int) {
    self tmp = *this;
    decrement();
    return tmp;
  }
};

inline bool operator==(const __rb_tree_base_iterator& x,
                       const __rb_tree_base_iterator& y) {
  return x.node == y.node;
  // 两个迭代器相等,指这两个迭代器指向的节点相等
}

inline bool operator!=(const __rb_tree_base_iterator& x,
                       const __rb_tree_base_iterator& y) {
  return x.node != y.node;
  // 两个节点不相等,指这两个迭代器指向的节点不等
}
```

迭代器的解引用运算,返回的是这个节点的值域.所以对于set来说,返回的就是set存储的值,对于map来说,返回的就是pair<key,value>键值对.

# 红黑树

---

为了实现红黑树的插入和删除平衡,STL树实现了几个旋转以及平衡函数:
```
inline void
__rb_tree_rotate_left(__rb_tree_node_base* x, __rb_tree_node_base*& root)

inline void
__rb_tree_rotate_right(__rb_tree_node_base* x, __rb_tree_node_base*& root)

inline void
__rb_tree_rebalance(__rb_tree_node_base* x, __rb_tree_node_base*& root)

inline __rb_tree_node_base*
__rb_tree_rebalance_for_erase(__rb_tree_node_base* z,
                              __rb_tree_node_base*& root,
                              __rb_tree_node_base*& leftmost,
                              __rb_tree_node_base*& rightmost)
```
这几个函数是实现红黑树平衡的重要操作,左旋转,右旋转,插入一个节点之后的平衡操作,删除一个节点的平衡操作.这几个函数较为复杂,我就不分析了,但是我觉得看网上的博客会比较好理解.

下面看下rb_tree真正的定义.先是创建节点和销毁节点:
```
 //分配节点存储空间
 link_type get_node() { return rb_tree_node_allocator::allocate(); }
  //回收一个节点的空间
  void put_node(link_type p) { rb_tree_node_allocator::deallocate(p); }

  //创建一个节点
  link_type create_node(const value_type& x) {
    link_type tmp = get_node();			// 配置空间
    __STL_TRY {
      construct(&tmp->value_field, x);	// 建造内容
    }
    __STL_UNWIND(put_node(tmp));
    return tmp;
  }

  link_type clone_node(link_type x) {	// 复制一个节点(主要是是颜色)
    link_type tmp = create_node(x->value_field);
    tmp->color = x->color;
    tmp->left = 0;
    tmp->right = 0;
    return tmp;
  }

  void destroy_node(link_type p) {
    destroy(&p->value_field);		// 解析内容
    put_node(p);					// 回收节点空间
  }
```
红黑树的成员主要有3个,
```
 size_type node_count; // 记录树的大小(节点的个数)
  link_type header;    
  Compare key_compare;	 // 节点间的比较器,应该是个函数对象
```
对于header,其实相当与链表中的头节点,不存储数据,可用于红黑树的入口.header的设计可以说的STL红黑树设计的一个亮点,header和root互为父节点,header的左节点指向最小的值,header的右节点指向最大的值,所以header也可以作为end()迭代器指向的值.图示如下:![header图示](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_038.png "");

接下来就是一些小函数,都是实现获取节点成员变量的函数,有一个需要提下:
```
static const Key& key(link_type x) { return KeyOfValue()(value(x)); }
```
KeyOfValue这是个函数对象,对于set和map的实现是不一样的,主要功能就是从一个节点中获取这个节点存储的键值,对于set而言,这个函数对象为 identity<value\_type>,这个函数对象返回的就是这个set存储的值,而对于map而言,这个函数对象为  select1st<value_type>,map的值域为pair对象,所以select1st就是获取这个pair的第一个成员.

接下就对重要函数做个简单的介绍,因为太复杂了,而且这篇文章主要是讲解set和map.

1. 对于set和multiset,map和multimap而言,最大的区别就是是否允许键值重复,而反应在红黑树上,则为插入函数的不同.set和map用的是insert_unique,而multiset和multimap用的是insert_equal函数.具体源码,我也是一知半解,所以就不分析了,误人子弟就不好了.

2. 有插入就有删除函数,红黑树提供的是erase函数,但是使用这个函数之后,可能导致红黑树不满足那5个条件,所以要调用 \_\_rb_tree_rebalance_for_erase来维持树的平衡.

3. 对于multiset和multimap而言,红黑树还提供了查询与某个键值相等的节点迭代器范围,
```
 pair<iterator,iterator> equal_range(const key_type& x);
```
这个函数返回二叉树中和键值x相等的迭代器范围.而set和map都是不允许键值重复的,所以就不要用这个函数,直接用find函数即可.
4. 红黑树还提供了查询不小于和大于某个键值的函数:
```
//返回不小于k的第一个节点迭代器
typename rb_tree<Key, Value, KeyOfValue, Compare, Alloc>::iterator
rb_tree<Key, Value, KeyOfValue, Compare, Alloc>::lower_bound(const Key& k)
//返回大于k的第一个节点迭代器
typename rb_tree<Key, Value, KeyOfValue, Compare, Alloc>::iterator
rb_tree<Key, Value, KeyOfValue, Compare, Alloc>::upper_bound(const Key& k)
```

# map实现

---------------


map底层用的是红黑树,所以map只是在红黑树上加了一层封装,map中用的用的红黑树定义如下:
```
 typedef Key key_type;	//键值类型 
 typedef T data_type;		// 值类型
 typedef T mapped_type;	//值类型
 typedef pair<const Key, T> value_type;	// 值类型,map存储pair键值对
 typedef Compare key_compare;	// 键值函数对象

  class value_compare//值域比较器,其实也是比较键值
    : public binary_function<value_type, value_type, bool> {
  friend class map<Key, T, Compare, Alloc>;
  protected :
    Compare comp;
    value_compare(Compare c) : comp(c) {}
  public:
    bool operator()(const value_type& x, const value_type& y) const {
      return comp(x.first, y.first);
    }
  };
  //map中红黑树的定义
  typedef rb_tree<key_type, value_type, 
                  select1st<value_type>, key_compare, Alloc> rep_type;
   rep_type t;
```
可以看到在map中,传入红黑树的KeyOfValue函数对象是select1st<value_type>,而value_type为pair类型,这个函数对象就是获取pair第一个键值,为了键值比较排序.


## map构造函数

map构造函数有分为默认构造函数和带比较函数对象的构造的构造函数,一个是用默认的比较对象less<key>,另一个是可以自己定义比较对象的构造函数
```
  map() : t(Compare()) {}
  explicit map(const Compare& comp) : t(comp) {}
```

map还支持用一对输入迭代器来初始化,迭代器之间即为要插入map的数据,所以可以将vector首尾迭代器作为参数传入map构造函数来初始化
```
 template <class InputIterator>
  map(InputIterator first, InputIterator last)
    : t(Compare()) { t.insert_unique(first, last); }

  template <class InputIterator>
  map(InputIterator first, InputIterator last, const Compare& comp)
    : t(comp) { t.insert_unique(first, last); }
```

map还支持值类型的数组指针范围来初始化map,例如pair<string,int> parr[10],然后用这个数组的首尾指针来初始化map.
```
  map(const value_type* first, const value_type* last)
    : t(Compare()) { t.insert_unique(first, last); }
  map(const value_type* first, const value_type* last, const Compare& comp)
    : t(comp) { t.insert_unique(first, last); }
```
## map插入操作

map插入分为单个值插入,在某个节点插入以及插入一对迭代器范围内的元素.
```
  pair<iterator,bool> insert(const value_type& x) { return t.insert_unique(x); }
  iterator insert(iterator position, const value_type& x) {
    return t.insert_unique(position, x);
  }
  void insert(const value_type* first, const value_type* last) {
    t.insert_unique(first, last);
  }
  void insert(const_iterator first, const_iterator last) {
    t.insert_unique(first, last);
  }
```
对于第一个迭代器,返回的是一个pair<iterator,bool>,迭代器指向插入节点的位置,布尔值为插入是否成功.其他都是简单的调用红黑树的方法.

## map删除操作

map删除操作提供删除某个迭代器指向的节点,某个键指向的节点,以及一对迭代器指向的元素:
```
  void erase(iterator position) { t.erase(position); }
  size_type erase(const key_type& x) { return t.erase(x); }
  void erase(iterator first, iterator last) { t.erase(first, last); }
```

## map查找函数

map查找函数有查找某个键值的find函数,查找某个键值个数的count函数,两个限界函数,最后查找范围的函数
```
 //查找某个键值对应的节点迭代器
 iterator find(const key_type& x) { return t.find(x); }
 //查找某个键值的个数
 size_type count(const key_type& x) const { return t.count(x); }
 //查找不小于,即大于等于键值x的节点迭代器,
 iterator lower_bound(const key_type& x) {return t.lower_bound(x); }
 //查找大于键值x的节点迭代器
 iterator upper_bound(const key_type& x) {return t.upper_bound(x); }
 //返回lower_bound和upper_bound迭代器对.
 pair<iterator,iterator> equal_range(const key_type& x) {
    return t.equal_range(x);
```

map一定要提到的函数是重载下标注运算符,这个函数也算是查找某个键所对应的值,但是如果某个键不存在的话,则会插入pair对,键值为k,值为data_type类型的默认值.
```
 T& operator[](const key_type& k) {
    return (*((insert(value_type(k, T()))).first)).second;
  }
```
这个函数有点复杂,insert(value_type(k, T()))先返回pair<iterator,bool>第一个iterator,即这个键所对应节点的迭代器,然后取这个键所对应的值pair<key_type,value_type>,最后取出第二个元素即可.

所以要查找某个元素不能用这个下标表示法,应该用find函数,因为前者会将不存在的键插入到map中.

# set的实现

---

先来看下set中红黑树的定义:
```
  typedef Key key_type;
  typedef Key value_type;
  // 键值和值域比较器是一样的,因为set存储的就是一个值,而不是键值对
  typedef Compare key_compare;
  typedef Compare value_compare;
  typedef rb_tree<key_type, value_type, 
                     identity<value_type>, key_compare, Alloc> rep_type;
   rep_type t;
```
这里面最重要的就是identity<value_type>函数对象了.这个就是获取set存储的value的键值部分.也是标准模板库的一部分.

看到这我才发现,set的接口和map的接口几乎一模一样...













