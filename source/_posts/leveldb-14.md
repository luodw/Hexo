title: leveldb源码分析之WriteBatch
date: 2015-10-30 19:22:37
tags:
- leveldb
- WriteBatch
categories:
- leveldb

toc: true

---

leveldb提供的接口除了针对一条记录的插入和删除操作之外，还提供了批量更新的操作，即writebatch类。writebatch类只有一个成员变量，存储的是若干条记录的序列号字符串，这个字符串是按照一定格式生成，当要取出这些记录时，也要按照格式一条一条解析出来。

<!--more-->

# WriteBatch类

先介绍下这个类的成员变量rep_，这个字符串用来存储这次批操作的所有记录，格式如下:
```
WriteBatch::rep_:=
	sequence: fixed64
	count: fixed32
	data: record[count]
record: kTypeValue varstring varstring
        kTypeDeletion varstring
varstring:
       len: varint32
       data: uint8[len]
```
可以看到这个这个字符串首先有有8字节的序列号和4字节的记录数作为头，所以这个类定义了
```
static const size_t KHeader=12
```

作为这个这个字符串的最小长度。在头之后，紧接着就是一条一条的记录。
1. 对于插入的记录，由kTypeValue+key长度+key+value长度+value组成
2. 对于删除记录，由kTypeDelete+key长度+key组成

在介绍这个WriteBatch这个类的操作函数之前，需要先介绍操作WriteBatch这个类的WriteBatchInternal。

# WriteBatchInternal类

这个类主要作用就是操作WriteBatch的字符串，比如取出/设置序列号，取出/设置记录数，将WriteBatch插入memtable等等。

来看下这个类的操作成员方法，全部声明为static方法:
```
int WriteBatchInternal::Count(const WriteBatch* b) {
  return DecodeFixed32(b->rep_.data() + 8);
}//获得这个WriteBatch的记录数

void WriteBatchInternal::SetCount(WriteBatch* b, int n) {
  EncodeFixed32(&b->rep_[8], n);
}//设置这个WriteBatch的记录数

SequenceNumber WriteBatchInternal::Sequence(const WriteBatch* b) {
  return SequenceNumber(DecodeFixed64(b->rep_.data()));
}//设置这个WriteBatch的序列号

void WriteBatchInternal::SetSequence(WriteBatch* b, SequenceNumber seq) {
  EncodeFixed64(&b->rep_[0], seq);
}//设置这个WriteBatch的序列号

static Slice Contents(const WriteBatch* batch) {
  return Slice(batch->rep_);
}//获得这个WriteBatch的所有内容

static size_t ByteSize(const WriteBatch* batch) {
  return batch->rep_.size();
}//获得这个WriteBatch的记录总和大小

Status WriteBatchInternal::InsertInto(const WriteBatch* b,
                                      MemTable* memtable) {
  MemTableInserter inserter;
  inserter.sequence_ = WriteBatchInternal::Sequence(b);
  inserter.mem_ = memtable;
  return b->Iterate(&inserter);
}//将这个WriteBatch的所有记录添加进memtable

void WriteBatchInternal::SetContents(WriteBatch* b, const Slice& contents) {
  assert(contents.size() >= kHeader);
  b->rep_.assign(contents.data(), contents.size());
}//设置这个WriteBatch的内容

void WriteBatchInternal::Append(WriteBatch* dst, const WriteBatch* src) {
  SetCount(dst, Count(dst) + Count(src));
  assert(src->rep_.size() >= kHeader);
  dst->rep_.append(src->rep_.data() + kHeader, src->rep_.size() - kHeader);
}//将src中的所有记录添加进dst中
```

# WriteBatch接口

介绍了上述这个操作WriteBatch类之后，接下来就来看下WriteBatch这类提供的接口，主要是将记录添加进rep_以及从rep_中解析出所有记录。

将记录添加到rep_接口为:
```
void WriteBatch::Put(const Slice& key, const Slice& value) {
  //先将记录数加1
  WriteBatchInternal::SetCount(this, WriteBatchInternal::Count(this) + 1);
  rep_.push_back(static_cast<char>(kTypeValue));//添加类型
  PutLengthPrefixedSlice(&rep_, key);//添加key的长度和值
  PutLengthPrefixedSlice(&rep_, value);//添加value的长度和值
}

void WriteBatch::Delete(const Slice& key) {
  //设置记录数加1
  WriteBatchInternal::SetCount(this, WriteBatchInternal::Count(this) + 1);
  //添加类型
  rep_.push_back(static_cast<char>(kTypeDeletion));
  //添加key以及key值
  PutLengthPrefixedSlice(&rep_, key);
}
```

在memtable是没有删除操作的，但是可以将记录分为正常的键值对和删除键类型。当搜索删除类型键值时，返回kNoFoun，表示memtable里面没有这条记录。等到compaction时才真正删除。

在介绍如何解析这个rep_成一条一条记录时，需要先介绍下MemTableInserter这个类，这个类继承自Handler这个抽象类，定义如下:

```
class MemTableInserter : public WriteBatch::Handler {
 public:
  SequenceNumber sequence_;
  MemTable* mem_;

  virtual void Put(const Slice& key, const Slice& value) {
    mem_->Add(sequence_, kTypeValue, key, value);
    sequence_++;
  }
  virtual void Delete(const Slice& key) {
    mem_->Add(sequence_, kTypeDeletion, key, Slice());
    sequence_++;
  }
};

```

这个类很简单，通过memtable将正常的键值对和删除类型的键值对添加进memtable。这个类将作为参数，传入rep_解析函数，如下；

```
Status WriteBatch::Iterate(Handler* handler) const {
  Slice input(rep_);
  if (input.size() < kHeader) {//字符串至少等于12
    return Status::Corruption("malformed WriteBatch (too small)");
  }

  input.remove_prefix(kHeader);移除头12个字节
  Slice key, value;
  int found = 0;//代表记录数
  while (!input.empty()) {
    found++;
    char tag = input[0];//获取类型
    input.remove_prefix(1);//移除一字节
    switch (tag) {
      case kTypeValue://正常键值对
        if (GetLengthPrefixedSlice(&input, &key) &&
            GetLengthPrefixedSlice(&input, &value)) {//解析出key和value
          handler->Put(key, value);//通过上述类添加进memtable中
        } else {
          return Status::Corruption("bad WriteBatch Put");
        }
        break;
      case kTypeDeletion://删除类型
        if (GetLengthPrefixedSlice(&input, &key)) {
          handler->Delete(key);//将删除类型键值添加进memtable
        } else {
          return Status::Corruption("bad WriteBatch Delete");
        }
        break;
      default:
        return Status::Corruption("unknown WriteBatch tag");
    }
  }
  if (found != WriteBatchInternal::Count(this)) {//判断添加的记录数是否等于WriteBatch中持有的记录数
    return Status::Corruption("WriteBatch has wrong count");
  } else {
    return Status::OK();
  }
}
```
这个方法解析出一条记录，然后判断记录的类型，根据不同的类型，调用Hander不同的方法将记录插入memtable中。这个方法最后由WriteBatchInternal这个类的InsertInto调用；

```
Status WriteBatchInternal::InsertInto(const WriteBatch* b,
                                      MemTable* memtable) {
  MemTableInserter inserter;
  inserter.sequence_ = WriteBatchInternal::Sequence(b);//公有成员，直接赋值
  inserter.mem_ = memtable;//公有成员，直接赋值
  return b->Iterate(&inserter);//调用WriteBatch的解析方法，将所有记录插入memtable
}

```

# 上层方法调用

在DBImpl最上层类中，当插入数据时，先是调用WriteBatch的put和delete方法将记录添加进rep_，然后调用WriteBatchInternal:InsertInto方法:

```
Status DBImpl::Put(const WriteOptions& o, const Slice& key, const Slice& val) {
  return DB::Put(o, key, val);
}

Status DBImpl::Delete(const WriteOptions& options, const Slice& key) {
  return DB::Delete(options, key);
}

Status DB::Put(const WriteOptions& opt, const Slice& key, const Slice& value) {
  WriteBatch batch;
  batch.Put(key, value);
  return Write(opt, &batch);
}

Status DB::Delete(const WriteOptions& opt, const Slice& key) {
  WriteBatch batch;
  batch.Delete(key);
  return Write(opt, &batch);
}
```
先是调用DB:Put和DB:Delete方法，这两个方法再调用Write将数据写到memtable。Write最终是先将rep_中的记录先添加进log文件，最后调用WriteBatchInternal:InsertInto方法，将记录添加进memtable。

# 写个小程序

我写个小程序来介绍下WriteBatch这个类是怎么用的。

```
#include<iostream>
#include<cassert>
#include<leveldb/db.h>
#include<leveldb/write_batch.h>

int main(void)
{
	leveldb::DB *db;
	leveldb::Options options;
	options.create_if_missing=true;
	leveldb::Status status=leveldb::DB::Open(options,"mydb",&db);
	assert(status.ok());
	std::string key1="book";
	std::string value1="algorithm";
	status=db->Put(leveldb::WriteOptions(),key1,value1);
	assert(status.ok());
	std::string value;
        status=db->Get(leveldb::ReadOptions(),key1,&value);
	assert(status.ok());
	std::cout<<"book:"<<value<<std::endl;
	leveldb::WriteBatch batch;
	batch.Delete(key1);
	std::string key2="fruit";
        std::string value2="apple";
	batch.Put(key2,value2);
	status=db->Write(leveldb::WriteOptions(),&batch);
	assert(status.ok());
	leveldb::Iterator *iter=db->NewIterator(leveldb::ReadOptions());
	for(iter->SeekToFirst();iter->Valid();iter->Next())
	{
		std::cout<<iter->key().ToString()<<":"<<iter->value().ToString()<<std::endl;
	}
	delete db;
	return 0;
}

```

这个程序先是添加一个键值对，book:algorithm，然后用WriteBatch进行批量操作，先是删除book:键值对，然后添加fruit::apple键值对，最后输出结果如下:

```
book:algorithm
fruit:apple

```
