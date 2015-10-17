title: leveldb源码分析之内存池Arena
date: 2015-10-15 19:12:47
tags:
- leveldb
- Arena
categories:
- leveldb

toc: true

---

这篇博客主要讲解下leveldb内存池，内存池很多地方都有用到，像linux内核也有个内存池。内存池的存在主要就是减少malloc或者new调用的次数，较少内存分配所带来的系统开销。

Arena类采用vector来存储每次分配内存的指针，每一次分配的内存，我们称为一个块block。block默认大小为4096kb。我们可以先看下Arena的模型：
![leveldb内存池Arena模型](http://7xjnip.com1.z0.glb.clouddn.com/luodwarena.jpg "")

我们来看看源码：
首先看下这个类的几个成员变量：
```
  char* alloc_ptr_;//内存的偏移量指针，即指向未使用内存的首地址
  size_t alloc_bytes_remaining_;//还剩下的内存数
  std::vector<char*> blocks_;//存储每一次分配的内存指针
  size_t blocks_memory_;//到目前为止分配的总内存。
```

构造函数和析构函数：
```
Arena::Arena() {
  blocks_memory_ = 0;
  alloc_ptr_ = NULL;  // First allocation will allocate a block
  alloc_bytes_remaining_ = 0;
}//构造函数初始化总总分配的内存为0，指针偏移量为NULL,剩余内存为0。
vector会调用默认构造函数初始化。

Arena::~Arena() {
  for (size_t i = 0; i < blocks_.size(); i++) {
    delete[] blocks_[i];
  }
}//Arena析构时，只需要把所有的指针指向的内存都delete就可以了。
```
都说谷歌的C++编程风格是最优美的。leveldb里面的每个类的构造函数都直接初始化所有的属性，这样就不会导致使用为初始化的变量，而且代码很清晰，知道哪些属性被初始化为何值。

接下来分析下Arena内存分配的主要函数。
```
public:
	char* Allocate(size_t bytes);
private:
	char* AllocateFallback(size_t bytes);
	char* AllocateNewBlock(size_t block_bytes);
```
Arena对外提供的接口是public里的函数，但是该函数会调用private里的两个函数.我分析内存分配策略。当要分配内存的时候：
1. 如果需求的内存小于剩余的内存，那么直接在剩余的内存分配就可以了；
2. 如果需求的内存大于剩余的内存，而且大于4096/4，则给这内存单独分配一块bytes（函数参数）大小的内存。
3. 如果需求的内存大于剩余的内存，而且小于4096/4，则重新分配一个内存块，默认大小4096，用于存储数据。

针对第二点，按源码的注释是说避浪费太多的剩余空间。我的理解是，如果剩余的内存为1500kb，那么假设有一个内存需求是500kb，一个内存需求是1500kb,则第一个需求可以使用三次才导致进行一次重新内存分配，而第二个只能使用一次就要进行一次重新内存分配。所以leveldb第二条的用意主要还是减少内存分配的次数。

源码如下：
```
inline char* Arena::Allocate(size_t bytes) {
  // The semantics of what to return are a bit messy if we allow
  // 0-byte allocations, so we disallow them here (we don't need
  // them for our internal use).
  assert(bytes > 0);
  if (bytes <= alloc_bytes_remaining_) {//需要的内存小于剩余的内存，直接分配，
//移动指针偏移量，减少剩余内存，返回刚分配内存的首位置
    char* result = alloc_ptr_;//先保存指针偏移量，用于返回
    alloc_ptr_ += bytes;//指针偏移量向上移动bytes个字节
    alloc_bytes_remaining_ -= bytes;//剩余内存减少bytes个字节
    return result;
  }
  return AllocateFallback(bytes);//当需求内存大于剩余内存时
}

char* Arena::AllocateFallback(size_t bytes) {
  if (bytes > kBlockSize / 4) {//需求内存大于1024kb时
    // Object is more than a quarter of our block size.  Allocate it separately
    // to avoid wasting too much space in leftover bytes.
    char* result = AllocateNewBlock(bytes);
    return result;
  }

  // We waste the remaining space in the current block.
  alloc_ptr_ = AllocateNewBlock(kBlockSize);//需求内存大于剩余内存，且小于1024时。
  alloc_bytes_remaining_ = kBlockSize;

  char* result = alloc_ptr_;
  alloc_ptr_ += bytes;
  alloc_bytes_remaining_ -= bytes;
  return result;
}

char* Arena::AllocateNewBlock(size_t block_bytes) {
  char* result = new char[block_bytes];//分配内存
  blocks_memory_ += block_bytes;//总的内存加上刚分配的内存
  blocks_.push_back(result);//添加进内存指针数组
  return result;
}
```
arena还提供了字节对齐内存分配，一般情况是8个字节对齐分配，即内存地址后三位必须为0.我们来看下源码，挺多学问的。
```
char* Arena::AllocateAligned(size_t bytes) {
  //用于判断对齐的大小，我64位电脑sizeof(void*)=8，不大于8，所以对齐大小为8。
  const int align = (sizeof(void*) > 8) ? sizeof(void*) : 8;
  //用于判断align是否为2的次幂，内存对齐肯定是2的次幂。
  assert((align & (align-1)) == 0);   
  //判断当前的模式，align-1后三位为1，其他都为0，所以指针与align-1做与运算，
//其实就是指针与align求余运算。例如如果地址值为9，9&7，则最后一位为1，9%8=1。
  size_t current_mod = reinterpret_cast<uintptr_t>(alloc_ptr_) & (align-1);
  //根据当前的模式，算出需要添加的字节数
  size_t slop = (current_mod == 0 ? 0 : align - current_mod);
  size_t needed = bytes + slop;//原来需求的字节大小，加上为了对齐补充的字节大小
  char* result;
  if (needed <= alloc_bytes_remaining_) {
    result = alloc_ptr_ + slop;
    alloc_ptr_ += needed;
    alloc_bytes_remaining_ -= needed;
  } else {
    // AllocateFallback always returned aligned memory
    result = AllocateFallback(bytes);
  }
  assert((reinterpret_cast<uintptr_t>(result) & (align-1)) == 0);
  return result;
}
```
这里边有一个uintptr\_t类型，定义在<stddef.h>头文件里，是无符号长整形类型，是typedef unsigned long int 类型，对应有符号类型为typedef long int intptr_t。这种类型是机器指针大小对应,如果32位系统，则uintptr\_t也为32位，如果是64位系统，则这个值为64位。

Arena最后一个对外接口是返回这个内存池分配总的内存大小。
```
size_t MemoryUsage() const {
    return blocks_memory_ + blocks_.capacity() * sizeof(char*);
  }
```
Arena内存大小包括分配的内存空间大小和所有指针大小之和。

Arena在memtabla（也就是跳跃链表）使用较多，因为刚插入的内存数据都放在了memtable里。

至此Arena就分析结束了。







