title: leveldb源码分析之读sst文件
date: 2015-10-24 20:20:16
tags:
- leveldb
- block
- sst文件
- table
categories:
- leveldb

toc: true

---

上篇文章介绍了leveldb缓冲池，这篇文章主要来分析leveldb是如何读取磁盘的数据。这里先要说明下，leveldb有两种缓冲池，一个是block_cache,另一个是table_cache。block\_cache缓冲的是data block，table\_cache缓冲的是每个sst文件的文件指针(RandomAccessFile指针)和这个文件对应的Table指针。

当leveldb要获取键值对时，首先检测键值对是否在缓冲池中，如果在，直接从缓冲池中获取；如果不在缓冲池中，则先从磁盘中获取相应的块，存储在缓冲池中，然后再从缓冲池中获取数据，如果系统的局部性很强的话，那么缓冲是可以大大减少磁盘IO时间的。

# block类
block类主要是磁盘的data block和index block在内存中的数据结构，当读取一个块时，首先把块内容存储在block里，然后table类再调用block的相应方法来处理数据。

所以先来看下block类的定义：
```
  const char* data_;//指向data block的内容首地址
  size_t size_;//data block数据长度
  uint32_t restart_offset_;     // 重启点数组的起始地址
  bool owned_;   //是否要用户自己delete这个block
  uint32_t NumRestarts() const;//返回这个block重启点的个数
  size_t size() const { return size_; }//这个块数据长度
  Iterator* NewIterator(const Comparator* comparator);//返回这个block的迭代器
```
先来看下这个类的构造函数
```
Block::Block(const BlockContents& contents)
    : data_(contents.data.data()),
      size_(contents.data.size()),
      owned_(contents.heap_allocated) {
  if (size_ < sizeof(uint32_t)) {
    size_ = 0;  // 一个block至少有一个重启点所占的字节数
  } else {
    size_t max_restarts_allowed = (size_-sizeof(uint32_t)) / sizeof(uint32_t);
    if (NumRestarts() > max_restarts_allowed) {
      // size太小
      size_ = 0;
    } else {
      //如果了解一个data block的布局，就知道重启点为啥是如下计算了。
      restart_offset_ = size_ - (1 + NumRestarts()) * sizeof(uint32_t);
    }
  }
}
```
这个构造函数出现一个BlockContent类型，这个类型用来存储从磁盘读取的数据，定义如下：
```
struct BlockContents {
  Slice data;           // data block数据
  bool cachable;        // 这个块是否放进缓存中，在ReadOption.fill_cache设置
  bool heap_allocated;  // 是否是用户自己分配的内存，如果是，则需要用户自己delete。
};
```
block这个类主要的接口就是返回这个类的迭代器，用于从data block中获取数据。我们来看下迭代器是如何实现的。
```
 const Comparator* const comparator_;//比较器
  const char* const data_;      // block的内容
  uint32_t const restarts_;     // 重启点数组的偏移量
  uint32_t const num_restarts_; // 重启点的个数
  //以上4个参数由block传进来，赋值之后就不再变化

  // current_ 指向正在读取的记录，如果current
  uint32_t current_;
  uint32_t restart_index_;  // 当前记录所在重启点区域
  std::string key_;//当前记录的键值
  Slice value_;//当前记录的值
  Status status_;//当前迭代器的状态
```
以上就是block的成员变量，由于该迭代器成员函数较多，我就从迭代器初始化到迭代器取出一个值的顺序分析下源码：

构造函数:
```
public:
  Iter(const Comparator* comparator,
       const char* data,
       uint32_t restarts,
       uint32_t num_restarts)
      : comparator_(comparator),
        data_(data),
        restarts_(restarts),
        num_restarts_(num_restarts),
        current_(restarts_),//当前记录指向重启点数组的首位置，表示无效
        restart_index_(num_restarts_) {//当前记录所在重启点索引=重启点个数，表示无效
    assert(num_restarts_ > 0);
  }
```
构造出一个迭代器之后，首先要将迭代器的当前记录指向首位置，当前记录所在索引赋值为0，函数如下：
```
  virtual void SeekToFirst() {
    SeekToRestartPoint(0);
    ParseNextKey();
  }
```
该函数调用了两个函数如下：
```
   void SeekToRestartPoint(uint32_t index) {
    key_.clear();//一开始key_为空
    restart_index_ = index;//当前记录所在重启点索引为0

    // ParseNextKey() starts at the end of value_, so set value_ accordingly
    uint32_t offset = GetRestartPoint(index);//找到这个索引重启点的偏移量
    value_ = Slice(data_ + offset, 0);//value_一开始指向记录的首位置
  }
  //解析当前记录
  bool ParseNextKey() {
    current_ = NextEntryOffset();//将要被解析记录的偏移量，一开始时，就是0
    const char* p = data_ + current_;//p指向将要被解析的记录首位置
    const char* limit = data_ + restarts_;  // 记录指针最大值为重启点数组首位置
    if (p >= limit) {
      // 表示迭代到data block最后一条记录结束
      current_ = restarts_;
      restart_index_ = num_restarts_;
      return false;
    }

    // 解析出当前记录
    uint32_t shared, non_shared, value_length;
    //解析当前记录的共享长度，非共享长度，值的长度，然后返回的指针p指向非共享内容的首位置
    p = DecodeEntry(p, limit, &shared, &non_shared, &value_length);
    if (p == NULL || key_.size() < shared) {
      CorruptionError();
      return false;
    } else {
      key_.resize(shared);//第一条记录共享长度为0
      key_.append(p, non_shared);//第一条记录的非共享内容就是第一条完整记录
      value_ = Slice(p + non_shared, value_length);//解析出value值
      while (restart_index_ + 1 < num_restarts_ &&
             GetRestartPoint(restart_index_ + 1) < current_) {
        ++restart_index_;//更新记录所在的重启点索引
      }
      return true;
    }
  }
};
```
这个函数非常重要，因为迭代器重要任务就是解析出记录。但是有一个难点，就是需要区分重启点第一条记录和非第一条记录的解析方式。
1. 当为第一条记录时，共享部分为0， key\_.append(p, non\_shared);这行代码就是将第一条完整记录加在key_后面。
2. 当不是第一条记录时，此时key\_.resize(shared);这行代码获取当前记录和上一条记录共享部分， key\_.append(p, non\_shared);这行代码就获得非共享部分，凑成完整的记录。

经过上述函数，此时这个迭代器的key_指向第一条记录的key，value_指向第一条记录的value.

最后一个就是返回这个block的迭代器函数;
```
Iterator* Block::NewIterator(const Comparator* cmp) {
  if (size_ < sizeof(uint32_t)) {
    return NewErrorIterator(Status::Corruption("bad block contents"));
  }
  const uint32_t num_restarts = NumRestarts();
  if (num_restarts == 0) {
    return NewEmptyIterator();
  } else {
    return new Iter(cmp, data_, restart_offset_, num_restarts);
  }
}
```
其他函数就不一一分析了，接下来，看下调用block，获取数据的Table类;

# Table类
Table这个类是sst文件在内存的数据结构，保存了sst文件的index block,meta block，文件指针等等。Table这个类读取数据时，先从Block_cache查询，如果找到了，就直接返回，否则就到磁盘获取。先来看下这个类的属性定义：
```
struct Table::Rep {
  ~Rep() {
    delete filter;
    delete [] filter_data;
    delete index_block;
  }

  Options options;//上层传进来的options
  Status status;//这个表格的状态
  RandomAccessFile* file;//这个Table代表的文件
  uint64_t cache_id;//缓存序号
  FilterBlockReader* filter;//读取Meta block类
  const char* filter_data;//Meta block数据

  BlockHandle metaindex_handle;  // 读取Metaindex_block的handle
  Block* index_block;//index Block
};
```
Table构造函数很简单，就是给Rep属性赋值。接来下，看下如何打开一个Table
```
Status Table::Open(const Options& options,
                   RandomAccessFile* file,
                   uint64_t size,
                   Table** table) {
  *table = NULL;
  if (size < Footer::kEncodedLength) {
    return Status::Corruption("file is too short to be an sstable");
  }

  char footer_space[Footer::kEncodedLength];//存储footer空间
  Slice footer_input;//footer内容
  Status s = file->Read(size - Footer::kEncodedLength, Footer::kEncodedLength,
                        &footer_input, footer_space);//从文件读取出footer
  if (!s.ok()) return s;

  Footer footer;
  s = footer.DecodeFrom(&footer_input);//从footer_input解码出footer这个类
  if (!s.ok()) return s;

  // 读取index block
  BlockContents contents;
  Block* index_block = NULL;
  if (s.ok()) {
    ReadOptions opt;
    if (options.paranoid_checks) {
      opt.verify_checksums = true;
    }
    s = ReadBlock(file, opt, footer.index_handle(), &contents);//读取sst文件一个块函数，有crc检查
    if (s.ok()) {
      index_block = new Block(contents);//转换为block类
    }
  }

  if (s.ok()) {
    // We've successfully read the footer and the index block: we're
    // ready to serve requests.
    Rep* rep = new Table::Rep;//给rep属性赋值
    rep->options = options;
    rep->file = file;
    rep->metaindex_handle = footer.metaindex_handle();
    rep->index_block = index_block;
    rep->cache_id = (options.block_cache ? options.block_cache->NewId() : 0);
    rep->filter_data = NULL;
    rep->filter = NULL;
    *table = new Table(rep);
    (*table)->ReadMeta(footer);//读取Metaindex block
  } else {
    if (index_block) delete index_block;
  }

  return s;
}

void Table::ReadMeta(const Footer& footer) {
  if (rep_->options.filter_policy == NULL) {
    return;  // 表示没有Metaindex block数据
  }

  // TODO(sanjay): Skip this if footer.metaindex_handle() size indicates
  // it is an empty block.
  ReadOptions opt;
  if (rep_->options.paranoid_checks) {
    opt.verify_checksums = true;
  }
  BlockContents contents;
  if (!ReadBlock(rep_->file, opt, footer.metaindex_handle(), &contents).ok()) {
    // Do not propagate errors since meta info is not needed for operation
    return;
  }
  Block* meta = new Block(contents);

  Iterator* iter = meta->NewIterator(BytewiseComparator());
  std::string key = "filter.";
  key.append(rep_->options.filter_policy->Name());
  iter->Seek(key);//查找目前过滤器Meta数据的handle
  if (iter->Valid() && iter->key() == Slice(key)) {
    ReadFilter(iter->value());//读取Meta block，也就是filter条目
  }
  delete iter;
  delete meta;
}

void Table::ReadFilter(const Slice& filter_handle_value) {
  Slice v = filter_handle_value;
  BlockHandle filter_handle;
  if (!filter_handle.DecodeFrom(&v).ok()) {//转换为BlockHandle
    return;
  }

  // We might want to unify with ReadBlock() if we start
  // requiring checksum verification in Table::Open.
  ReadOptions opt;
  if (rep_->options.paranoid_checks) {
    opt.verify_checksums = true;//需要CRC检查
  }
  BlockContents block;
  if (!ReadBlock(rep_->file, opt, filter_handle, &block).ok()) {//将Meta数据读入block
    return;
  }
  if (block.heap_allocated) {
    rep_->filter_data = block.data.data();//Meta block过滤数据
  }
  rep_->filter = new FilterBlockReader(rep_->options.filter_policy, block.data);
}
```
这个函数主要功能就是创建一个sst文件的Table结构。将index block和meta block读进内存，方便后续的操作

接下来分析下Table读取一个block的函数。这个函数就涉及到将数据读进缓存，所以先介绍下block_cache的格式。

![block_cache键值对格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Block_cache.jpg "");

解释下：key值由这个block的cache_id和这个block在文件的偏移量组成，value即为这个block的block对象。

好，现在来分析下这个函数;
```
Iterator* Table::BlockReader(void* arg,
                             const ReadOptions& options,
                             const Slice& index_value) {
  Table* table = reinterpret_cast<Table*>(arg);
  Cache* block_cache = table->rep_->options.block_cache;
  Block* block = NULL;
  Cache::Handle* cache_handle = NULL;

  BlockHandle handle;
  Slice input = index_value;//需要读取BlockHandle
  Status s = handle.DecodeFrom(&input);
  // We intentionally allow extra stuff in index_value so that we
  // can add more features in the future.

  if (s.ok()) {
    BlockContents contents;
    if (block_cache != NULL) {//如果设置了block_cache
      char cache_key_buffer[16];//block_cache的键值
      EncodeFixed64(cache_key_buffer, table->rep_->cache_id);//前8字节存储cache_id
      EncodeFixed64(cache_key_buffer+8, handle.offset());//后8字节存储这个block的偏移量
      Slice key(cache_key_buffer, sizeof(cache_key_buffer));
      cache_handle = block_cache->Lookup(key);//在缓存中查找这个cache_handle
      if (cache_handle != NULL) {//如果缓存找到，直接用缓存中的block
        block = reinterpret_cast<Block*>(block_cache->Value(cache_handle));
      } else {//如果缓存中没有
        s = ReadBlock(table->rep_->file, options, handle, &contents);从磁盘中读取出这个块
        if (s.ok()) {
          block = new Block(contents);
          if (contents.cachable && options.fill_cache) {
            cache_handle = block_cache->Insert(//如果这个块设置了可缓存，插入缓存中
                key, block, block->size(), &DeleteCachedBlock);
          }
        }
      }
    } else {//如果没设置block_cache，直接磁盘读取
      s = ReadBlock(table->rep_->file, options, handle, &contents);
      if (s.ok()) {
        block = new Block(contents);
      }
    }
  }

  Iterator* iter;
  if (block != NULL) {
    iter = block->NewIterator(table->rep_->options.comparator);//获取这个块的迭代器
    if (cache_handle == NULL) {
      iter->RegisterCleanup(&DeleteBlock, block, NULL);//如果没有设置缓存，那么注册删除block函数
    } else {
      iter->RegisterCleanup(&ReleaseBlock, block_cache, cache_handle);//如果设置了缓存，那么注册释放block函数，就是引用数减1.
    }
  } else {
    iter = NewErrorIterator(s);
  }
  return iter;
}
```
这个函数最后是当构造Table的迭代器时，作为函数指针传进构造函数中，Table的迭代器为两层迭代器，什么叫两层迭代器了？我的理解是：如果要读取一个sst文件的某个键值对，首先要读取data block，然后才是从这个data block中读取键值对。所以有两次迭代，即两个迭代器。

简要分析下，先看下Table返回两层迭代器的函数：
```
Iterator* Table::NewIterator(const ReadOptions& options) const {
  return NewTwoLevelIterator(
      rep_->index_block->NewIterator(rep_->options.comparator),首先穿进去的index block的迭代器，用于读取data block
      &Table::BlockReader, const_cast<Table*>(this), options);
}
```

# TwoLevelIterator类
分析下两次迭代器，不算很难懂，属性如下：
```
  BlockFunction block_function_;//就是传进来的BlockReader函数
  void* arg_;//Table指针
  const ReadOptions options_;//读取配置选项
  Status status_;
  IteratorWrapper index_iter_;//index block迭代器，就是上述第一个参数
  IteratorWrapper data_iter_; // 可能为空，读取某个data block的迭代器
  // If data_iter_ is non-NULL, then "data_block_handle_" holds the
  // "index_value" passed to block_function_ to create the data_iter_.
  std::string data_block_handle_;//用于判断两次data_iter是否相等。
```
鉴于迭代函数都挺多，我还是一样，读取第一条记录作为样本讲解，首先构造成功之后，定位到哦第一条记录：
```
void TwoLevelIterator::SeekToFirst() {
  index_iter_.SeekToFirst();//index_block迭代器指向第一条记录，也就是第一个块的blockhandle
  InitDataBlock();
  if (data_iter_.iter() != NULL) data_iter_.SeekToFirst();
  SkipEmptyDataBlocksForward();
}

void TwoLevelIterator::InitDataBlock() {
  if (!index_iter_.Valid()) {
    SetDataIterator(NULL);
  } else {
    Slice handle = index_iter_.value();//指向第一个块的handle
    if (data_iter_.iter() != NULL && handle.compare(data_block_handle_) == 0) {
      // data_iter_不为空，而且还是相同块的迭代器，所以不变
    } else {
      Iterator* iter = (*block_function_)(arg_, options_, handle);//调用BlockReader，获取这个块的迭代器。
      data_block_handle_.assign(handle.data(), handle.size());//为data_block_handle_赋值，用于判断两次data_iter_是否相等
      SetDataIterator(iter);//设置data_iter_
    }
  }
}
```
经过这两个函数之后，index_iter_指向index_block第一条记录，data_iter_指向第一个块的首位置。接下来通过查询来分析下两层迭代器如何获取数据。
```
void TwoLevelIterator::Seek(const Slice& target) {
  index_iter_.Seek(target);//找到target所以块的handle
  InitDataBlock();//初始化data_iter_，即指向target所在的块首位置
  if (data_iter_.iter() != NULL) data_iter_.Seek(target);//如果没报错即找到了，通过data_iter_.value即可获取值。
  SkipEmptyDataBlocksForward();
}

void TwoLevelIterator::SkipEmptyDataBlocksForward() {
  while (data_iter_.iter() == NULL || !data_iter_.Valid()) {
    // Move to next block
    if (!index_iter_.Valid()) {
      SetDataIterator(NULL);
      return;
    }
    index_iter_.Next();
    InitDataBlock();
    if (data_iter_.iter() != NULL) data_iter_.SeekToFirst();
  }
}
```
如果查询到了，代码还是很好理解的，关键是如果没有查询到时，我还不是很理解。

从sst读取文件暂时分析到此。总结下，先 构造一个sst文件的Table类，然后构造出Table的迭代器，从迭代器就可以获取这个文件的任何键值。












