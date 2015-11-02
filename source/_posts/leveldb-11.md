title: leveldb源码分析之Cache
date: 2015-10-24 14:14:45
tags:
- leveldb
- Cache
categories:
- leveldb

toc: true

---
缓存对于一个系统的性能有着重要的影响。试想，如果leveldb每次查询数据时，都要从磁盘获取数据，那么磁盘多次的磁盘IO将严重影响leveldb的性能。所以levledb就在内存设计了一个缓存区，当查询数据时，先到缓存查询，如果缓存有需要的数据，即可直接返回数据即可，无需到磁盘获取数据；如果缓存没有，则到磁盘将数据取出放到缓存，下次再查询相同数据时，即可直接从缓存获取，大大减少了磁盘IO。

缓存在操作系统中更常见。例如，如果要读取文件，也是要先到操作系统内核缓存获取数据，内核缓存是以page为单位，没有再到磁盘中获取；还有CPU要从内存获取数据时，也是先在Cache中查询等等。

好，我们来看下leveldb的缓存设计。leveldb的缓存主要是由NewLRUCache这个类负责的，然后这个类包含了16个LRUCache，LRUCache这个类才是真正的缓存类，也就是说levledb包含了16个缓存。LRUCache这个类是一个环形双向链表组成的缓存，同时LRUCache还包含一个hash表，同样是存储缓存项，主要是为了加快查询速度。

以下这个图是我自己画的示意图，没有画出哈希表：

![leveldb缓存示意图](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Cache.jpg "");

先给出缓存中代表键值对的数据结构：
```
struct LRUHandle {
  void* value;//存储键值对的值
  void (*deleter)(const Slice&, void* value);//这个结构体的清除函数，由外界传进去注册
  LRUHandle* next_hash;//用于hash表冲突时使用
  LRUHandle* next;//当前节点的下一个节点
  LRUHandle* prev;//当前节点的上一个节点
  size_t charge;      // 这个节点占用的内存
  size_t key_length;//这个节点键值的长度
  uint32_t refs;//这个节点引用次数，当引用次数为0时，即可删除
  uint32_t hash;      // 这个键值的哈希值
  char key_data[1];   // 存储键的字符串，也是C++柔性数组的概念。

  Slice key() const {
    // For cheaper lookups, we allow a temporary Handle object
    // to store a pointer to a key in "value".
    if (next == this) {
      return *(reinterpret_cast<Slice*>(value));
    } else {
      return Slice(key_data, key_length);
    }
  }//那句英文的意思就是，为了加速查询，有时候一个节点在value存储键。
};
```
这个就是缓存中存储键值对的数据结构，键值对主要储存在key_data[1]和value里面。
# HandleTable
接下来看下hash表的源码分析，源码挺长的，先看下成员数属性：
```
  uint32_t length_;//哈希数组的长度
  uint32_t elems_;//哈希表存储元素的数量
  LRUHandle** list_;//哈希数组指针，因为数组存储的是指针，所以类型必须是指针的指针
```
主要接口函数有：
```
//在哈希表中，通过key和hash值查询LRUHandle，在删除，添加，查询时有用到
LRUHandle** FindPointer(const Slice& key, uint32_t hash)
//在哈希表查询一个LRUHandle
LRUHandle* Lookup(const Slice& key, uint32_t hash) 
//在哈希表中删除一个LRUHandle
LRUHandle* Remove(const Slice& key, uint32_t hash)
//在哈希表中添加一个LRUHandle
 LRUHandle* Insert(LRUHandle* h)
//改变哈希表的大小
void Resize()
```
构造函数很简单，
```
HandleTable() : length_(0), elems_(0), list_(NULL) { Resize(); }
```
先是对成员初始化，然后调用Resize()，因为一开始没有哈希表，所以先给哈希表分配存储空间。第一次分配时，哈希数组长度为4，当后面元素数量大于哈希表长度时，再次分配哈希表大小为现在数组长度的2倍。
```
  void Resize() {
    uint32_t new_length = 4;//第一次默认分配大小数组长度为4
    while (new_length < elems_) {
      new_length *= 2;//后续分配为目前长度的2倍
    }
    //以下是做重新哈希的工作，因为数组长度变化了，所以元素需要重新哈希
    LRUHandle** new_list = new LRUHandle*[new_length];//给哈希数组长度分配空间
    memset(new_list, 0, sizeof(new_list[0]) * new_length);//数组初始化为0
    uint32_t count = 0;
    for (uint32_t i = 0; i < length_; i++) {
      LRUHandle* h = list_[i];//h为数组的的元素，代表某个LRUHandle指针
      while (h != NULL) {//第i个哈希链的遍历
        LRUHandle* next = h->next_hash;//当前节点的下一个节点
        uint32_t hash = h->hash;//当前节点的哈希值
        LRUHandle** ptr = &new_list[hash & (new_length - 1)];//当前节点在新哈希数组中的索引位置
        h->next_hash = *ptr;//这句话在同一个哈希链上插入第二个元素时，更好理解
        *ptr = h;//索引位置赋值
        h = next;//开始迭代下一个元素
        count++;//哈希数组中所有元素
      }
    }
    assert(elems_ == count);
    delete[] list_;//析构原有哈希数组
    list_ = new_list;//list_指向新的哈希数组
    length_ = new_length;//更新长度
  }
};
```
第一次执行Resize时，不执行for循环，因为lenght_长度为0，所以就是新建一个空的哈希表。我来解释下h->next_hash = *ptr;我第一次没看懂这句话，所以我觉得有点难理解。
1. 一开始，*ptr值为空，所以h->next_hash值为0；
2. 然后执行\*ptr = h，把h赋值给\*ptr，所以\*ptr指向h。
3. 当这条哈希链再来一个元素时，此时执行h->next_hash = *ptr;\*ptr存储的是第一个节点的地址，然后新来的节点插在了第一个节点的前面。
4. 最后执行*ptr = h，新哈希表的索引位置就存储第二个节点的地址。

当插入，删除，查询时，都要先找到节点的地址，调用函数如下：
```
  LRUHandle** FindPointer(const Slice& key, uint32_t hash) {
    LRUHandle** ptr = &list_[hash & (length_ - 1)];//根据hash值，节点在哈希表中的索引位置
    while (*ptr != NULL &&
           ((*ptr)->hash != hash || key != (*ptr)->key())) {
      ptr = &(*ptr)->next_hash;//迭代哈希链，找到键值相等的节点
    }
    return ptr;返回这个节点的地址的地址
  }
```

先看下简单的查询操作;
```
LRUHandle* Lookup(const Slice& key, uint32_t hash) {
    return *FindPointer(key, hash);
  }
```

插入操作,先查找要插入的键值是否在哈希表中，如果在，那么用新的节点替换就的节点，并且函数返回旧的节点。
```
LRUHandle* Insert(LRUHandle* h) {
    LRUHandle** ptr = FindPointer(h->key(), h->hash);//查找要插入的节点的地址
    LRUHandle* old = *ptr;
    h->next_hash = (old == NULL ? NULL : old->next_hash);//这行和下一行将新节点插入到哈希链中
    *ptr = h;
    if (old == NULL) {//当old为空时，不存在相等的节点
      ++elems_;//元素个数+1
      if (elems_ > length_) {
        // Since each cache entry is fairly large, we aim for a small
        // average linked list length (<= 1).
        Resize();
      }
    }
    return old;
  }

```
为了保证哈希链的查找速度，尽量使平均哈希链长度为<=1。所以函数有if判断。

接下来，是哈希表删除函数，找到要删除的节点，更新即可：
```
  LRUHandle* Remove(const Slice& key, uint32_t hash) {
    LRUHandle** ptr = FindPointer(key, hash);//查找要删除的节点位置
    LRUHandle* result = *ptr;//把要删除的节点地址赋给result
    if (result != NULL) {
      *ptr = result->next_hash;//删除节点的位置赋值给删除节点的下一个节点
      --elems_;//元素减一
    }
    return result;
  }
```
# LRUCache类

接下来，我们来分析下双向链表缓存类LRUCache,先看下主要成员：
```
  size_t capacity_;//这个双向链表的存储容量，由每个节点的charge累加和
  port::Mutex mutex_;//这个链表的互斥量
  size_t usage_;//已使用空间
  LRUHandle lru_;//双向循环链表的傀儡节点，不存储数据，方便定位这个链表的入口
  HandleTable table_;//上面讲解的哈新表，所以一个链表还附带一个哈希表
```
lru之前(prev)的节点都是最新的节点，lru之后的节点(next)都是最“旧”的节点，所以插入新节点时，就往lru.prev插入.当空间不够时，删除lru.next后的节点。

构造函数如下：
```
LRUCache::LRUCache()
    : usage_(0) {
  // 一开始为空的循环链表，所以lru的前后指针都指向自己
  lru_.next = &lru_;
  lru_.prev = &lru_;
}
```
向链表append一个节点，调用的是void LRUCache::LRU_Append(LRUHandle* e)，这个函数由insert函数调用;
```
void LRUCache::LRU_Append(LRUHandle* e) {
  // 往lru_之前插入，使这个节点为最新节点
  e->next = &lru_;
  e->prev = lru_.prev;
  e->prev->next = e;
  e->next->prev = e;
}

Cache::Handle* LRUCache::Insert(
    const Slice& key, uint32_t hash, void* value, size_t charge,
    void (*deleter)(const Slice& key, void* value)) {
  MutexLock l(&mutex_);//多线程使用时，删除添加均需要锁住

  LRUHandle* e = reinterpret_cast<LRUHandle*>(
      malloc(sizeof(LRUHandle)-1 + key.size()));//给插入的节点分配空间
  e->value = value;
  e->deleter = deleter;
  e->charge = charge;
  e->key_length = key.size();
  e->hash = hash;
  e->refs = 2;  // 链表引用一次，返回值引用一次
  memcpy(e->key_data, key.data(), key.size());//给键值赋值
  LRU_Append(e);//调用上述函数，添加进循环链表
  usage_ += charge;/链表空间使用量更新

  LRUHandle* old = table_.Insert(e);//同时往哈希表插入节点
  if (old != NULL) {
    LRU_Remove(old);//如果哈希表用新的节点替换了旧节点，那么循环链表也要删除旧节点
    Unref(old);
  }

  while (usage_ > capacity_ && lru_.next != &lru_) {//缓存不够用时，从循环链表的lru.next开始删除节点，同时也要把哈希表的节点删除
    LRUHandle* old = lru_.next;
    LRU_Remove(old);
    table_.Remove(old->key(), old->hash);
    Unref(old);
  }

  return reinterpret_cast<Cache::Handle*>(e);返回新插入节点的指针
}
```
删除节点的函数比较简单，我就不多说了。

# ShardedLRUCache类
这个类主要是一个封装类，封装类16个LRUCache类，就是16个环形链表+哈希表。根据键的哈希值，调用相应的LRUCache类的方法。

先看两个简单的函数：
```
  static inline uint32_t HashSlice(const Slice& s) {
    return Hash(s.data(), s.size(), 0);
  }//返回这个键值的哈希值，调用hash函数

  static uint32_t Shard(uint32_t hash) {
    return hash >> (32 - kNumShardBits);
  }//用hash值最高的4位，来决定用那个LRUCache来操作这个键值
```
主要接口如下，可以看到都是调用LRUCache里的方法
```
  explicit ShardedLRUCache(size_t capacity)
      : last_id_(0) {
    const size_t per_shard = (capacity + (kNumShards - 1)) / kNumShards;
    for (int s = 0; s < kNumShards; s++) {
      shard_[s].SetCapacity(per_shard);
    }
  }
  virtual ~ShardedLRUCache() { }
  virtual Handle* Insert(const Slice& key, void* value, size_t charge,
                         void (*deleter)(const Slice& key, void* value)) {
    const uint32_t hash = HashSlice(key);
    return shard_[Shard(hash)].Insert(key, hash, value, charge, deleter);
  }
  virtual Handle* Lookup(const Slice& key) {
    const uint32_t hash = HashSlice(key);
    return shard_[Shard(hash)].Lookup(key, hash);
  }
  virtual void Release(Handle* handle) {
    LRUHandle* h = reinterpret_cast<LRUHandle*>(handle);
    shard_[Shard(h->hash)].Release(handle);
  }
  virtual void Erase(const Slice& key) {
    const uint32_t hash = HashSlice(key);
    shard_[Shard(hash)].Erase(key, hash);
  }
  virtual void* Value(Handle* handle) {
    return reinterpret_cast<LRUHandle*>(handle)->value;
  }
  virtual uint64_t NewId() {
    MutexLock l(&id_mutex_);
    return ++(last_id_);
  }
};
```
看了leveldb缓存，我对缓存机制有了深刻的理解，大概就知道内核的缓存是如何实现的了，所以多看看优秀开源源码，可以学习到很多东西。













