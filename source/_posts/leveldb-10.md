title: leveldb源码分析之写sst文件
date: 2015-10-21 22:02:27
tags:
- leveldb
- block
- filterpolicy
- tablebuilder
- blockbuilder
categories:
- leveldb

toc: true

---
本篇文章分析下leveldb写sst文件的源码，本质上就是为immemtable compaction到leveldb0文件提供接口，主要是插入。如果要理解这部分的源码，首先必须先将上篇sst文件格式搞清楚，否则，看源码会非常吃力，或者说毫无头绪。

这部分源码涉及到table文件下的block_builder.h/.cc，filter_block.h/.cc和table_builder.h/.cc。先分析下block_builder.h/.cc文件，主要功能就是用于写data block和index block。向外提供主要接口就是void BlockBuilder::Add(const Slice& key, const Slice& value) .

# BlockBuilder类
首先，看这个类的类名就知道这个类是用来构造一个块的，data block和index block都是通过这个类构造出来的。来看下这个类的成员变量有哪些：
```
 const Options*        options_;      //Option类，由最上层open函数传进来，这里主要用于counter_ < options_->block_restart_interval)
//判断两个Restart节点之间，记录数量是否小于option定义的值
  std::string           buffer_;      // 这个块的所有数据，数据一条一条添加到这个string中
  std::vector<uint32_t> restarts_;    // 存储每一个Restart[i]
  int                   counter_;     // 两个Restart之间记录的条数
  bool                  finished_;    // 是否调用finish，也就是是否写完一个块。
  std::string           last_key_;    //每次写记录时的上一条记录，用于提供共享记录部分
```
因为这个类就要是为了构造块，所以这个类首先要提供add键值对的接口，其次是要有返回这个块所有数据的接口，便于上层接口将数据写到磁盘中，所以主要接口如下：
```
//构造函数
explicit BlockBuilder(const Options* options);
//重置block的各个属性，准备下一次写
void Reset();
//往当前块添加一条记录
void Add(const Slice& key, const Slice& value);
//当前块写结束，返回这个块的所有内容，在tablebuilder写入文件
Slice Finish();
//估计这个块的数据量，用于判断当前块是否大于option当中定义数据块大小
size_t CurrentSizeEstimate() const;
```
接下来，分析每个函数的源码，构造函数如下;
```
BlockBuilder::BlockBuilder(const Options* options)
    : options_(options),
      restarts_(),
      counter_(0),
      finished_(false) {
    assert(options->block_restart_interval >= 1);
    restarts_.push_back(0); 
}
```
发现构造函数没有什么好分析的，就最后一句。因为第一条肯定是Restart点，所以把0地址添加进restarts。

重置函数源码如下：

```
kBuilder::Reset() {
  buffer_.clear();//块内容清零
  restarts_.clear();//Restart节点清零
  restarts_.push_back(0); //把0偏移加到Restart节点
  counter_ = 0;//两个Restart节点之间记录数清零
  finished_ = false;//还未结束
  last_key_.clear();//last_key清零
}
```
接下来是这个块内容大小的估计函数
```

size_t BlockBuilder::CurrentSizeEstimate() const {
  return (buffer_.size() +                        // 数据容量大小
          restarts_.size() * sizeof(uint32_t) +   //Restart数组大小 
          sizeof(uint32_t));  //Restart数组大小值所占的字节
```
这个函数主要用于判断某个块的容量是否到达上限，到达之后，要把数据刷新到磁盘，然后重新开始写下一个块。

接下来是这个类最重要的函数，add添加键值对函数，这里还是把记录格式在贴出来，方便对照：
![data block记录格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--记录格式.jpg "")
```
void BlockBuilder::Add(const Slice& key, const Slice& value) {
  Slice last_key_piece(last_key_);//上一条记录
  assert(!finished_);//这个块还没写结束，如果结束，再添加会报错
  assert(counter_ <= options_->block_restart_interval);//两个Restart节点之间记录数小于等于预先设定的值
  assert(buffer_.empty() 
         || options_->comparator->Compare(key, last_key_piece) > 0);//后面添加的键比上条记录大，skiplist有序
  size_t shared = 0;
  if (counter_ < options_->block_restart_interval) {
    // 计算当前记录和上条记录共享部分长度
    const size_t min_length = std::min(last_key_piece.size(), key.size());
    while ((shared < min_length) && (last_key_piece[shared] == key[shared])) {
      shared++;
    }
  } else {
    // 如果上面if语句为false，则添加一个Restart节点，counter_=0。
    restarts_.push_back(buffer_.size());
    counter_ = 0;
  }
    const size_t non_shared = key.size() - shared;//当前记录和上条记录非共享部分长度

  // 将shared,non_shared,value的长度添加进buffer_
  PutVarint32(&buffer_, shared);
  PutVarint32(&buffer_, non_shared);
  PutVarint32(&buffer_, value.size());

  // 添加当前记录的非共享内容和vlue内容
  buffer_.append(key.data() + shared, non_shared);
  buffer_.append(value.data(), value.size());

  // 更新上一条记录，即为当前记录
  last_key_.resize(shared);
  last_key_.append(key.data() + shared, non_shared);
  assert(Slice(last_key_) == key);
  counter_++;
}
```
这个函数需要注意的是，每个Restart节点的共享部分为0,，因为没有上一条记录嘛。然后按协议封装好一条完整记录添加到buffer_即可，接下来，就是finish函数做的事了。
```
Slice BlockBuilder::Finish() {
  // 将Restart数组添加到记录后面
  for (size_t i = 0; i < restarts_.size(); i++) {
    PutFixed32(&buffer_, restarts_[i]);
  }
  PutFixed32(&buffer_, restarts_.size());//添加Restart数组大小到Restart数组后面
  finished_ = true;//这次数据块写结束
  return Slice(buffer_);//向上层调用返回这个数据块的内容
}
```
这个函数主要是向table_builder提供返回这个块内容的接口，然后由table_builder调用函数写回磁盘。

# FilterBlockBuilder类
这个类用于写Meta block，也就是创建过滤器。先来分析主要成员变量：
```
  const FilterPolicy* policy_;    //过滤策略，比较有名的是布隆过滤器
  std::string keys_;              // 每一个Fliter条目包含的键值
  std::vector<size_t> start_;     // 每个Filter条目包含键值的首地址偏移量，相对于keys_首地址来说
  std::string result_;            // 到目前为止，所有Filter天幕包含的数据
  std::vector<Slice> tmp_keys_;   // 临时slice向量，用于向result_添加本次keys_数据
  std::vector<uint32_t> filter_offsets_;//每个Filter的偏移量
```
接下来介绍下主要函数：

开始创建Fliter条目函数
```
void FilterBlockBuilder::StartBlock(uint64_t block_offset) {
  uint64_t filter_index = (block_offset / kFilterBase);//kFilterBase默认大小为2>>11
  assert(filter_index >= filter_offsets_.size());
  while (filter_index > filter_offsets_.size()) {
    GenerateFilter();//创建Filter条目
  }
}
```
在table_builder.cc中，当一个块被刷新到磁盘时，就调用一次start_block函数，而触发块刷新的条件是，这个块的大小>=r->options.block_size=4096，所以每次都创建一个Filter，但是Filter有两个数组指向>=2的Filter条目。

创建Filer条目函数:
```
void FilterBlockBuilder::GenerateFilter() {
  const size_t num_keys = start_.size();//这个Filter键值的个数
  if (num_keys == 0) {
    // 添加下一个Filter条目的偏移量
    filter_offsets_.push_back(result_.size());
    return;
  }

  // 往result_添加key值
  start_.push_back(keys_.size());  // 简化长度计算
  tmp_keys_.resize(num_keys);
  for (size_t i = 0; i < num_keys; i++) {
    const char* base = keys_.data() + start_[i];
    size_t length = start_[i+1] - start_[i];
    tmp_keys_[i] = Slice(base, length);
  }

  //添加Filter偏移量以及将keys_添加进result_。
  filter_offsets_.push_back(result_.size());
  policy_->CreateFilter(&tmp_keys_[0], num_keys, &result_);

  //重置以下三个成员变量
  tmp_keys_.clear();
  keys_.clear();
  start_.clear();
}
```
Filter i添加键值的函数:
```
void FilterBlockBuilder::AddKey(const Slice& key) {
  Slice k = key;
  start_.push_back(keys_.size());
  keys_.append(k.data(), k.size());//添加键值
}
```
表示Meta block块写结束的函数:
```
Slice FilterBlockBuilder::Finish() {
  if (!start_.empty()) {
    GenerateFilter();//为剩下的键值对创建Filter。
  }

  // 将Filter i的偏移量数组添加到result_
  const uint32_t array_offset = result_.size();
  for (size_t i = 0; i < filter_offsets_.size(); i++) {
    PutFixed32(&result_, filter_offsets_[i]);
  }

  PutFixed32(&result_, array_offset);//将Filter i偏移量数组大小添加进result_
  result_.push_back(kFilterBaseLg);  // 添加beselg值
  return Slice(result_);//向上层函数返回这个Meta block的内容。
}
```
# TableBuilder类
这个类主要功能就是创建一个sst文件，它调用了block_builder和filerblockbuilder。这个类属性有点多，需要好好记清楚了。
```
struct TableBuilder::Rep {
  Options options;//上层传进来的optians，就是open函数的参数
  Options index_block_options;//暂时没看出用处
  WritableFile* file;//sst文件封装类
  uint64_t offset;//sst文件的偏移量，每写一个块，就更新一次
  Status status;//这个类操作的状态
  BlockBuilder data_block;//写数据块的类
  BlockBuilder index_block;//写index_block的类
  std::string last_key;//用于写index block时最大键值 
  int64_t num_entries;//这个块总的记录数
  bool closed;          // 调用finish或者abandon，文件写结束
  FilterBlockBuilder* filter_block;//创建过滤器的类
  bool pending_index_entry;//data block为空时，该值为true,用于写handler
  BlockHandle pending_handle;  // 用于写index block的handler
  std::string compressed_output;//转换为压缩的字符串
```
关键还是data_block，因为data_block要用多次，写块，刷新到磁盘，重置块等等。C++中用class代替struct，这里展示了struct用的场景之一，就是类里成员变量太多时，可以用struct封装。

接下来，主要介绍table_builder主要函数。

往data block添加一条记录函数：
```
void TableBuilder::Add(const Slice& key, const Slice& value) {
  Rep* r = rep_;
  assert(!r->closed);
  if (!ok()) return;
  if (r->num_entries > 0) {
    assert(r->options.comparator->Compare(key, Slice(r->last_key)) > 0);
  }//后续的key大于上条记录的key

  if (r->pending_index_entry) {//当data_block为空时，将上个datablock的handler添加到index block
    assert(r->data_block.empty());
    r->options.comparator->FindShortestSeparator(&r->last_key, key);
    std::string handle_encoding;
    r->pending_handle.EncodeTo(&handle_encoding);//将handle解码到字符串handle_encoding
    r->index_block.Add(r->last_key, Slice(handle_encoding));///index_block添加一条记录
    r->pending_index_entry = false;//赋值为false，开始新一个数据块写
  }

  if (r->filter_block != NULL) {
    r->filter_block->AddKey(key);//如果有定义过滤器，将这条记录键值添加到meta block的filter条目中
  }

  r->last_key.assign(key.data(), key.size());//重置last_key
  r->num_entries++;//记录数+1
  r->data_block.Add(key, value);数据块添加记录

  const size_t estimated_block_size = r->data_block.CurrentSizeEstimate();
  if (estimated_block_size >= r->options.block_size) {
    Flush();//当这个数据块的数据量大于预先设置的值时，刷新到磁盘
  }
}
```
刷新函数为：

```
void TableBuilder::Flush() {
  Rep* r = rep_;
  assert(!r->closed);
  if (!ok()) return;
  if (r->data_block.empty()) return;
  assert(!r->pending_index_entry);
  WriteBlock(&r->data_block, &r->pending_handle);//将数据写回缓冲区
  if (ok()) {
    r->pending_index_entry = true;
    r->status = r->file->Flush();//数据刷新到磁盘
  }
  if (r->filter_block != NULL) {
    r->filter_block->StartBlock(r->offset);//重新开启一个Filter条目
  }
}
```
刷新操作主要有以下步骤：
1. 将这个块的数据刷新到磁盘。因为底层调用的是c标准io流，所以数据是先写到用户态的缓存中，然后调用flush，再刷新到磁盘。
2. 在WriteBlock函数内部还在index block添加一条记录。
3. 重新开启一条Filter条目。

接下来是WriteBlock函数：
```
void TableBuilder::WriteBlock(BlockBuilder* block, BlockHandle* handle) {
  assert(ok());
  Rep* r = rep_;
  Slice raw = block->Finish();//data block原生内容

  Slice block_contents;
  CompressionType type = r->options.compression;//是否将数据压缩
  // TODO(postrelease): Support more compression options: zlib?
  switch (type) {
    case kNoCompression:
      block_contents = raw;
      break;

    case kSnappyCompression: {
      std::string* compressed = &r->compressed_output;
      if (port::Snappy_Compress(raw.data(), raw.size(), compressed) &&
          compressed->size() < raw.size() - (raw.size() / 8u)) {
        block_contents = *compressed;
      } else {
        // Snappy not supported, or compressed less than 12.5%, so just
        // store uncompressed form
        block_contents = raw;
        type = kNoCompression;
      }
      break;
    }
  }
  WriteRawBlock(block_contents, type, handle);//真正写操作
  r->compressed_output.clear();
  block->Reset();//重置data block，用于下次写
}
```
这个函数主要是用于判断data block的数据是否要压缩存储，真正下操作在下面函数：
```
void TableBuilder::WriteRawBlock(const Slice& block_contents,
                                 CompressionType type,
                                 BlockHandle* handle) {
  Rep* r = rep_;
  handle->set_offset(r->offset);//设置当前块的偏移量
  handle->set_size(block_contents.size());//设置当前块的大小
  r->status = r->file->Append(block_contents);//将内容写进用户态缓冲区
  if (r->status.ok()) {
    char trailer[kBlockTrailerSize];
    trailer[0] = type;
    uint32_t crc = crc32c::Value(block_contents.data(), block_contents.size());
    crc = crc32c::Extend(crc, trailer, 1);  // Extend crc to cover block type
    EncodeFixed32(trailer+1, crc32c::Mask(crc));
    r->status = r->file->Append(Slice(trailer, kBlockTrailerSize));
    if (r->status.ok()) {
      r->offset += block_contents.size() + kBlockTrailerSize;//写进一个块，这时sst文件偏移量增加
    }
  }
}
```
这个函数主要作用就是将数据写进用户态缓冲区，添加类型和CRC码，更新偏移量。

最后还有一个sst文件写完成函数，用于上层函数调用：
```
Status TableBuilder::Finish() {
  Rep* r = rep_;
  Flush();//刷新最后的数据
  assert(!r->closed);
  r->closed = true;

  BlockHandle filter_block_handle, metaindex_block_handle, index_block_handle;

  // 写Meta block，调用filterblockbuilder的finish函数返回所有内容
  if (ok() && r->filter_block != NULL) {
    WriteRawBlock(r->filter_block->Finish(), kNoCompression,
                  &filter_block_handle);//将这个meta block的偏移量和写进filter_block_handle，用于metaindex block写
  }

  // 写metaindex block
  if (ok()) {
    BlockBuilder meta_index_block(&r->options);
    if (r->filter_block != NULL) {
      // meta_index block块内容格式为"filter.Name"
      std::string key = "filter.";
      key.append(r->options.filter_policy->Name());
      std::string handle_encoding;
      filter_block_handle.EncodeTo(&handle_encoding);
      meta_index_block.Add(key, handle_encoding);
    }

    // TODO(postrelease): Add stats and other meta blocks
    WriteBlock(&meta_index_block, &metaindex_block_handle);
  }

  // 写index block
  if (ok()) {
    if (r->pending_index_entry) {
      r->options.comparator->FindShortSuccessor(&r->last_key);
      std::string handle_encoding;
      r->pending_handle.EncodeTo(&handle_encoding);
      r->index_block.Add(r->last_key, Slice(handle_encoding));
      r->pending_index_entry = false;
    }//写finish里flush函数刷新的数据块的偏移量和大小
    WriteBlock(&r->index_block, &index_block_handle);
  }

  // 写Footer
  if (ok()) {
    Footer footer;
    footer.set_metaindex_handle(metaindex_block_handle);
    footer.set_index_handle(index_block_handle);
    std::string footer_encoding;
    footer.EncodeTo(&footer_encoding);
    r->status = r->file->Append(footer_encoding);
    if (r->status.ok()) {
      r->offset += footer_encoding.size();//更新偏移量
    }
  }
  return r->status;
}
```
至此，一个sst文件就建好了。最后还有一个函数，用于调用table_builder来创建sst文件，在builder.h/.cc里,这个等到compaction是再分析。

leveldb将immemtable compcation到sst0就这样分析结束，接下来，就是读sst文件，读总是比写更复杂。。。
