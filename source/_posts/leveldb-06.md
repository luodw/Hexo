title: leveldb源码分析之memtable
date: 2015-10-17 10:15:49
tags:
- leveldb
- memtable
- varint
- lookupkey
categories:
- leveldb

toc: true

---

在讲memtable之前，有必要先讲讲leveldb模型,当向leveldb写入数据时，首先将数据写入log文件，然后在写入memtable内存中。log文件主要是用在当断电时，内存中数据会丢失，数据可以从log文件中恢复。当memtable数据达到一定大小即（options属性write_buffer_size大小，默认4<<20)，会变为immemtable，然后log文件也生成一个新的log文件.immemtable数据将会被持久化到磁盘中。模型图如下：
![leveldb模型图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-1360076329_9985.JPG "")
取自博客“sparkliang的专栏”

所以memtable算是leveldb重要组件之一。在介绍memtable时，需要先简单介绍几个知识点。

## 整型数据存储
leveldb所有数据都是字符形式，即使是整型，也将被转换为字符型存储。这样的好处就是可以减少内存空间的使用。例如，假如有一个int型数据，小于128，存储为整型时，需要占用四个字节，存储为字符型时，只需要一个字节即可。leveldb有两种整型和字符型数据转换。一种是fixed，一种是varint。

### fixed转换
fixed转换相对简单，就是将int的每一个字节存入字符数组中即可。举个简单例子：
```
void EncodeFixed32(char* buf, uint32_t value) {
  if (port::kLittleEndian) {//如果是小端，直接内存复制即可，不知道小端的，百度。
    memcpy(buf, &value, sizeof(value));
  } else {
    buf[0] = value & 0xff;//如果是大端，则需要一个一个字节的复制，先复制第一个字节
    buf[1] = (value >> 8) & 0xff;//复制第二个字节
    buf[2] = (value >> 16) & 0xff;//复制第三个字节
    buf[3] = (value >> 24) & 0xff;//复制第四个字节
  }
}

解码（从字符串到整型）也相对简单
inline uint32_t DecodeFixed32(const char* ptr) {
  if (port::kLittleEndian) {
    // Load the raw bytes
    uint32_t result;
    memcpy(&result, ptr, sizeof(result));  // 小端直接内存复制即可
    return result;
  } else {
    return ((static_cast<uint32_t>(static_cast<unsigned char>(ptr[0])))
	//取最小字节
        | (static_cast<uint32_t>(static_cast<unsigned char>(ptr[1])) << 8)
	//取第二字节，并且向左移动8个字节，作为整型的第二个字节，下面也是如此
        | (static_cast<uint32_t>(static_cast<unsigned char>(ptr[2])) << 16)
        | (static_cast<uint32_t>(static_cast<unsigned char>(ptr[3])) << 24));
  }
}
```
固定长度编码还有64位类型，在文件coding.cc中

### varint
这种转型将一个字节分成两部分，前7个字节存储数据，第8个字节表示高位是否还有数据。简单例子：
```
char* EncodeVarint32(char* dst, uint32_t v) {
  // Operate on characters as unsigneds
  unsigned char* ptr = reinterpret_cast<unsigned char*>(dst);
  static const int B = 128;//128二进制为1000 0000
  if (v < (1<<7)) {
    *(ptr++) = v;//如果v小于128，则将v低7位复制给ptr，ptr第8位为0，表示高位没数据，ptr+1
  } else if (v < (1<<14)) {
    *(ptr++) = v | B;//v的低7位复制为ptr的低7位，ptr第8位为1，表示高位还有数据。
    *(ptr++) = v>>7;////再把v的高7位复制为（ptr+1)的低7位，(ptr+1)第8位为0，表示高位没有数据了。下面分析也是一样。
  } else if (v < (1<<21)) {
    *(ptr++) = v | B;
    *(ptr++) = (v>>7) | B;
    *(ptr++) = v>>14;
  } else if (v < (1<<28)) {
    *(ptr++) = v | B;
    *(ptr++) = (v>>7) | B;
    *(ptr++) = (v>>14) | B;
    *(ptr++) = v>>21;
  } else {
    *(ptr++) = v | B;
    *(ptr++) = (v>>7) | B;
    *(ptr++) = (v>>14) | B;
    *(ptr++) = (v>>21) | B;
    *(ptr++) = v>>28;
  }
  return reinterpret_cast<char*>(ptr);
}

解析主要代码如下：
const char* GetVarint32PtrFallback(const char* p,
                                   const char* limit,
                                   uint32_t* value) {
  uint32_t result = 0;
  for (uint32_t shift = 0; shift <= 28 && p < limit; shift += 7) {
    uint32_t byte = *(reinterpret_cast<const unsigned char*>(p));//取出p指向的字节
    p++;//指向下一个字节
    if (byte & 128) {
      // 高位还有数据，继续循环
      result |= ((byte & 127) << shift);//每7位移动一次，分别向result7位赋值。
    } else {
      result |= (byte << shift);//最后七位，最高为一定为0.
      *value = result;
      return reinterpret_cast<const char*>(p);
    }
  }
```
解析varint的代码，思想主要就是取出字符数组的每一个字节，然后取出低7位的值，赋值给result的低7位。如果有第二个字节，则取出第二个字节得到低7位，向左移动7位，然后赋给result的8~14位。后续也是如此。

## leveldb键的形式
第一次看leveldb源码，会被Leveldb的多种key给弄混了。
首先是internalkey，格式为：
```
|user key|sequence number|type|
internal key size=key_size+8
```
ParsedInternalKey:
```
|user key|sequence number|type|
```
skiplist内部存储的key，格式为:
```
VarInt(interbal key size)len | internal key | VarInt(value) len | value |
```
membtable传入的是LookupKey：
```
|internal key size|internalkey|
```
LookupKey定义如下：
```
class LookupKey {
 public:
  // Initialize *this for looking up user_key at a snapshot with
  // the specified sequence number.
  LookupKey(const Slice& user_key, SequenceNumber sequence);

  ~LookupKey();

  // Return a key suitable for lookup in a MemTable.
  Slice memtable_key() const { return Slice(start_, end_ - start_); }
  //memtable_key本质上和LookupKey一样。
  // Return an internal key (suitable for passing to an internal iterator)
  Slice internal_key() const { return Slice(kstart_, end_ - kstart_); }

  // Return the user key
  Slice user_key() const { return Slice(kstart_, end_ - kstart_ - 8); }

 private:
  // We construct a char array of the form:
  //    klength  varint32               <-- start_
  //    userkey  char[klength]          <-- kstart_
  //    tag      uint64
  //                                    <-- end_
  // The array is a suitable MemTable key.
  // The suffix starting with "userkey" can be used as an InternalKey.
  const char* start_;
  const char* kstart_;
  const char* end_;
  char space_[200];      // Avoid allocation for short keys

  // No copying allowed
  LookupKey(const LookupKey&);
  void operator=(const LookupKey&);
};

```
## memtable
memtable主要功能就是为上层调用插入数据提供接口，所以memtable主要有三个公有接口，Get,Add,NewIterator，分别是获取某个键值，添加某个键值，以及获取迭代memtable的迭代器。私有成员主要有四个：
```
 typedef SkipList<const char*, KeyComparator> Table;
 struct KeyComparator {
    const InternalKeyComparator comparator;
    explicit KeyComparator(const InternalKeyComparator& c) : comparator(c) { }
    int operator()(const char* a, const char* b) const;
 };

 KeyComparator comparator_;//比较器
  int refs_;//饮用次数
  Arena arena_;//内存池
  Table table_;//skiplist
```

memtable构造函数：
```
MemTable::MemTable(const InternalKeyComparator& cmp)
    : comparator_(cmp),//InternalkeyComparator来初始化comoparator_
      refs_(0),//引用次数为0
      table_(comparator_, &arena_) {//跳跃链表初始化
}
```

memtable插入一条记录：
```
void MemTable::Add(SequenceNumber s, ValueType type,
                   const Slice& key,
                   const Slice& value) {
  // Format of an entry is concatenation of:
  //  key_size     : varint32 of internal_key.size()
  //  key bytes    : char[internal_key.size()]
  //  value_size   : varint32 of value.size()
  //  value bytes  : char[value.size()]
  size_t key_size = key.size();////键值长度
  size_t val_size = value.size();//值的长度
  size_t internal_key_size = key_size + 8;//InternalKey的长度
  const size_t encoded_len =
      VarintLength(internal_key_size) + internal_key_size +
      VarintLength(val_size) + val_size;//skiplist节点键的长度
  char* buf = arena_.Allocate(encoded_len);//分配键值内存
  char* p = EncodeVarint32(buf, internal_key_size);//键值长度存入buf中
  memcpy(p, key.data(), key_size);//键的内容存入buf
  p += key_size;//指针向后移动key_size个字节
  EncodeFixed64(p, (s << 8) | type);//序列号和类型
  p += 8;
  p = EncodeVarint32(p, val_size);//值的长度
  memcpy(p, value.data(), val_size);//值的内容
  assert((p + val_size) - buf == encoded_len);
  table_.Insert(buf);//插入到skiplist中
}
```
memtable插入操作很简单的，只要按协议封装好键值即可，最后插入skiplist中。

memtable读取操作：
```
bool MemTable::Get(const LookupKey& key, std::string* value, Status* s) {
  Slice memkey = key.memtable_key();//取出memtable_key
  Table::Iterator iter(&table_);获得skiplist的迭代器
  iter.Seek(memkey.data());//迭代器查找
  if (iter.Valid()) {
    // entry format is:
    //    klength  varint32
    //    userkey  char[klength]
    //    tag      uint64
    //    vlength  varint32
    //    value    char[vlength]
    // Check that it belongs to same user key.  We do not check the
    // sequence number since the Seek() call above should have skipped
    // all entries with overly large sequence numbers.
    const char* entry = iter.key();
    uint32_t key_length;
    const char* key_ptr = GetVarint32Ptr(entry, entry+5, &key_length);
    if (comparator_.comparator.user_comparator()->Compare(
            Slice(key_ptr, key_length - 8),
            key.user_key()) == 0) {//如果找到了key值
      // Correct user key
      const uint64_t tag = DecodeFixed64(key_ptr + key_length - 8);//取出标签，判断类型
      switch (static_cast<ValueType>(tag & 0xff)) {
        case kTypeValue: {//是正常值的类型
          Slice v = GetLengthPrefixedSlice(key_ptr + key_length);
          value->assign(v.data(), v.size());
          return true;
        }
        case kTypeDeletion://要删除的类型
          *s = Status::NotFound(Slice());
          return true;
      }
    }
  }
  return false;
}
```
memtable迭代器定义如下：
```
class MemTableIterator: public Iterator {
 public:
  explicit MemTableIterator(MemTable::Table* table) : iter_(table) { }

  virtual bool Valid() const { return iter_.Valid(); }
  virtual void Seek(const Slice& k) { iter_.Seek(EncodeKey(&tmp_, k)); }
  virtual void SeekToFirst() { iter_.SeekToFirst(); }
  virtual void SeekToLast() { iter_.SeekToLast(); }
  virtual void Next() { iter_.Next(); }
  virtual void Prev() { iter_.Prev(); }
  virtual Slice key() const { return GetLengthPrefixedSlice(iter_.key()); }
  virtual Slice value() const {
    Slice key_slice = GetLengthPrefixedSlice(iter_.key());
    return GetLengthPrefixedSlice(key_slice.data() + key_slice.size());
  }

  virtual Status status() const { return Status::OK(); }

 private:
  MemTable::Table::Iterator iter_;
  std::string tmp_;       // For passing to EncodeKey

  // No copying allowed
  MemTableIterator(const MemTableIterator&);
  void operator=(const MemTableIterator&);
};
```
memtable迭代器本质是调用skiplist的迭代器，代理模式。leveldb为了接口的简单，一层一层的封装，memtable属于内存部分的封装，接来文章，将关于log文件的封装。

返回memtable迭代器;
```
Iterator* MemTable::NewIterator() {
  return new MemTableIterator(&table_);
}
```
至此memtable分析结束。




