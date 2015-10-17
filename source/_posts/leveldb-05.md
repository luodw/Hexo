title: leveldb源码分析之Skiplist
date: 2015-10-16 19:35:20
tags:
- leveldb
- skiplist
categories:
- leveldb

toc: true

---

leveldb在内存中存储数据的区域称为memtable，这个memtable底层是用跳跃链表skiplist来实现的。redis也采用跳跃链表来实现有序链表。

skiplist的效率可以和平衡树媲美，平均O(logN)，最坏O(N)的查询效率，但是用skiplist实现比平衡树实现简单，所以很多程序用跳跃链表来代替平衡树。

leveldb是支持多线程操作的，但是skiplist并没有使用linux下锁，信号量来实现同步控制，据说是因为锁机制导致某个线程占有资源，其他线程阻塞的情况，导致系统资源利用率降低。所以leveldb采用的是**内存屏障**来实现同步机制。有时间要好好研究下内存屏障的知识，挺有比格的。

先看下skiplist链表的模型图：
![Skiplist模型图](http://7xjnip.com1.z0.glb.clouddn.com/luodw--skiplist.jpg "")


## 内存屏障
leveldb实现的skiplist看起来有点复杂，主要是用到泛型类以及内存屏障。我们先来看下内存屏障AtomicPointer类，即原子类操作：
```
class AtomicPointer {
 private:
  void* rep_;//原子指针
 public:
  AtomicPointer() { }
  explicit AtomicPointer(void* p) : rep_(p) {}
  inline void* NoBarrier_Load() const { return rep_; }//无需同步获取数据
  inline void NoBarrier_Store(void* v) { rep_ = v; }//无需同步设置数据
  inline void* Acquire_Load() const {
    void* result = rep_;
    MemoryBarrier();//先设置result的值，然后检查rep_是否有变化，如果有变化，
//则result重新从内存中获取数据。可以保持数据最新
    return result;
  }
  inline void Release_Store(void* v) {
    MemoryBarrier();//先更新rep_的值，然后再设置为v.
    rep_ = v;
  }
};


inline void MemoryBarrier() {
  // See http://gcc.gnu.org/ml/gcc/2003-04/msg01180.html for a discussion on
  // this idiom. Also see http://en.wikipedia.org/wiki/Memory_ordering.
  __asm__ __volatile__("" : : : "memory");//这句话表示当内存的中的数据被修改时，
//其他处理器上的寄存器和cache上这个变量的副本都将失效，必须从内存中重新获取。
}
```
内存屏障主要用处就是保证内存数据和处理器寄存器和缓存数据一致性。因为当某个处理器上改变某个变量x时，那么其他处理器上的x的副本都必须失效，否则将会读取错误值。

## skiplist节点 
接下来，我们看下skiplist节点源代码：
```
template<typename Key, class Comparator>
struct SkipList<Key,Comparator>::Node {
  explicit Node(const Key& k) : key(k) { }

  Key const key;

  // Accessors/mutators for links.  Wrapped in methods so we can
  // add the appropriate barriers as necessary.
  Node* Next(int n) {
    assert(n >= 0);
    // Use an 'acquire load' so that we observe a fully initialized
    // version of the returned Node.
    return reinterpret_cast<Node*>(next_[n].Acquire_Load());
  }//获取当前节点的下一个节点

  void SetNext(int n, Node* x) {
    assert(n >= 0);
    // Use a 'release store' so that anybody who reads through this
    // pointer observes a fully initialized version of the inserted node.
    next_[n].Release_Store(x);//设置当前节点的下个节点。
  }

  // No-barrier variants that can be safely used in a few locations.
  Node* NoBarrier_Next(int n) {
    assert(n >= 0);
    return reinterpret_cast<Node*>(next_[n].NoBarrier_Load());
  }//无需内存屏障的查找下一个节点

  void NoBarrier_SetNext(int n, Node* x) {
    assert(n >= 0);
    next_[n].NoBarrier_Store(x);
  }无需内存屏障的设置下一个节点

 private:
  // Array of length equal to the node height.  next_[0] is lowest level link.
  port::AtomicPointer next_[1];//节点的层数。
};
```
这是skiplist节点类，可以查找下一个节点，可以设置下一个节点。nect_[1]是一个很优秀的设计。只定义数组第一个节点，然后分配内存时，分配（高度-1）个数组类型的内存。其实就是动态分配内存。否则一开始用数组分配大数组，易造成内存浪费。

## skiplist实现
skiplist成员变量有：
```
    enum { kMaxHeight = 12 };//定义skiplist链表最高节点
  // Immutable after construction
  Comparator const compare_;//比较器有最顶层的options通过一层一层传递下来，用于///链表排序
  Arena* const arena_;    // leveldb内存池，从memtable传过来

  Node* const head_;//skiplist头节点

  // Modified only by Insert().  Read racily by readers, but stale
  // values are ok.
  port::AtomicPointer max_height_;   // skiplist目前的最高高度
    // Read/written only by Insert().
  Random rnd_;//随机类，用于随机化一个节点高度
```
enum{kMaxHeight = 12}也是很优秀设计，《efficetive C++》有一个章节有讲到尽量不要使用宏定义定义常量，取代的办法是const常量和enum类型。

skiplist构造函数如下;
```
template<typename Key, class Comparator>
SkipList<Key,Comparator>::SkipList(Comparator cmp, Arena* arena)
    : compare_(cmp),
      arena_(arena),
      head_(NewNode(0 /* any key will do */, kMaxHeight)),
      max_height_(reinterpret_cast<void*>(1)),
      rnd_(0xdeadbeef) {
  for (int i = 0; i < kMaxHeight; i++) {
    head_->SetNext(i, NULL);
  }
}
```
cmp和arena_都是调用者传进来，head_头指针key初始化为0,高度为链表高度上限。max_height_初始化为1.for循环将头节点的前一个节点都设为NULL。

分配一个新节点的源码如下：
```
template<typename Key, class Comparator>
typename SkipList<Key,Comparator>::Node*
SkipList<Key,Comparator>::NewNode(const Key& key, int height) {
  char* mem = arena_->AllocateAligned(
      sizeof(Node) + sizeof(port::AtomicPointer) * (height - 1));//从内存池里面分配
//足够的内存，用于存储新节点。
  return new (mem) Node(key);//返回这个节点。
}
```
接来看下skiplist插入一个新节点的代码，思想是，在插入高度为height的节点时，首先要找到这个节点height个前节点，然后插入就和普通的链表插入一样。
```
template<typename Key, class Comparator>
void SkipList<Key,Comparator>::Insert(const Key& key) {
  Node* prev[kMaxHeight];//kMaxHeight个前节点，因为高度还未知，所以先设为最大值
  Node* x = FindGreaterOrEqual(key, prev);//查找key值节点前GetMaxHeight()个前节点。

  assert(x == NULL || !Equal(key, x->key));

  int height = RandomHeight();//随机化一个节点高度
  if (height > GetMaxHeight()) {//如果当前节点的高度大于最高节点，则高出部分的的前节
//点都是头节点。
    for (int i = GetMaxHeight(); i < height; i++) {
      prev[i] = head_;
    }
    max_height_.NoBarrier_Store(reinterpret_cast<void*>(height));
  }

  x = NewNode(key, height);//新建节点
  for (int i = 0; i < height; i++) {
    x->NoBarrier_SetNext(i, prev[i]->NoBarrier_Next(i))//设立当前节点的后节点;
    prev[i]->SetNext(i, x);//设立当前节点的前节点。
  }
}
```
插入节点逻辑其实和单链表类似，只是查找前后节点麻烦点，需要找到不止一个。接下来是判断链表是否含有某个key值的接口：
```
template<typename Key, class Comparator>
bool SkipList<Key,Comparator>::Contains(const Key& key) const {
  Node* x = FindGreaterOrEqual(key, NULL);//返回第0层上个节点
  if (x != NULL && Equal(key, x->key)) {//如果x不为NULL,且key值与x的key值相等，则说明key在链表中。
    return true;
  } else {
    return false;
  }
}
```
链表是没有删除接口的，但是有删除功能。因为当我们插入数据时，key的形式为key:value，当删除数据时，则插入key:deleted类似删除的标记，等到Compaction再删除。

## skiplist迭代器
leveldb用的最多的就是迭代器了，最后我们来分析链表迭代器，分析迭代器，为看STL源码也积累基础。声明如下：
```
class Iterator {
   public:
    // Initialize an iterator over the specified list.
    // The returned iterator is not valid.
    explicit Iterator(const SkipList* list);

    // Returns true iff the iterator is positioned at a valid node.
    bool Valid() const;

    // Returns the key at the current position.
    // REQUIRES: Valid()
    const Key& key() const;

    // Advances to the next position.
    // REQUIRES: Valid()
    void Next();

    // Advances to the previous position.
    // REQUIRES: Valid()
    void Prev();

    // Advance to the first entry with a key >= target
    void Seek(const Key& target);

    // Position at the first entry in list.
    // Final state of iterator is Valid() iff list is not empty.
    void SeekToFirst();

    // Position at the last entry in list.
    // Final state of iterator is Valid() iff list is not empty.
    void SeekToLast();

   private:
    const SkipList* list_;//迭代器迭代的跳跃链表
    Node* node_;//指向当前的节点
    // Intentionally copyable
  };
```
迭代器的成员变量有，需要遍历的链表，以及指向当前节点的节点指针。

链表迭代器构造函数如下
```
template<typename Key, class Comparator>
inline SkipList<Key,Comparator>::Iterator::Iterator(const SkipList* list) {
  list_ = list;
  node_ = NULL;
}
```
迭代器具体实现代码如下：
```
template<typename Key, class Comparator>
inline bool SkipList<Key,Comparator>::Iterator::Valid() const {
  return node_ != NULL;
}//判断迭代器当前节点是否有效

template<typename Key, class Comparator>
inline const Key& SkipList<Key,Comparator>::Iterator::key() const {
  assert(Valid());
  return node_->key;
}//返回当前节点的key值

template<typename Key, class Comparator>
inline void SkipList<Key,Comparator>::Iterator::Next() {
  assert(Valid());
  node_ = node_->Next(0);
}//跳跃链表的第0层就是单链表，所以可以直接指向下一个节点

template<typename Key, class Comparator>
inline void SkipList<Key,Comparator>::Iterator::Prev() {
  // Instead of using explicit "prev" links, we just search for the
  // last node that falls before key.
  assert(Valid());
  node_ = list_->FindLessThan(node_->key);
  if (node_ == list_->head_) {
    node_ = NULL;
  }
}//查找当前节点的上一个节点。

template<typename Key, class Comparator>
inline void SkipList<Key,Comparator>::Iterator::Seek(const Key& target) {
  node_ = list_->FindGreaterOrEqual(target, NULL);
}//查找某个特定的key值的节点。

template<typename Key, class Comparator>
inline void SkipList<Key,Comparator>::Iterator::SeekToFirst() {
  node_ = list_->head_->Next(0);
}//查找第一个节点

template<typename Key, class Comparator>
inline void SkipList<Key,Comparator>::Iterator::SeekToLast() {
  node_ = list_->FindLast();
  if (node_ == list_->head_) {
    node_ = NULL;
  }
}//最后一个节点
```
还有一些函数我并没有列出，都是这些主函数的辅助函数，很简单，都能看懂。至此，跳跃链表就这样分析结束，下一篇，介绍memtable。




