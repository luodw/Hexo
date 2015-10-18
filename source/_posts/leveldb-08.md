title: leveldb源码分析之读写log文件
date: 2015-10-18 17:16:38
tags:
- leveldb
- log
- log::reader
- log::writer
categories:
- leveldb

toc: true

---

这篇文章讲讲leveldb第二大组件log文件的读写。log文件也可以称为恢复日志。当leveldb插入数据时，先插入log日志文件中，接着再插入内存memtable中。这样以来，万一在使用过程中，突然断电，memtable还来不及把数据持久化到磁盘时，内存数据就不会丢失，这时就可以从log文件中恢复。redis也有类似文件。

log文件按块划分，默认每块为32768kb=32M。这么大有个好处，就是减少从磁盘读取数据的次数，减少磁盘IO。可以看如下图：
![log文件模型](http://7xjnip.com1.z0.glb.clouddn.com/luodw--log.jpg "");
这个图中有3个block。然后每一条数据的格式：
![log记录格式](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_017.png "");
log文件每一条记录由四个部分组成：
1. CheckSum，即CRC验证码，占4个字节
2. 记录长度，即数据部分的长度，2个字节
3. 类型，这条记录的类型，后续讲解，1个字节
4. 数据，就是这条记录的数据。

关于记录的类型，平常使用中有4种：
1. FULL，表示这是一条完整的记录
2. FIRST，表示这是一条记录的第一部分。
3. MIDDLE，表示这是一条记录的中间部分。
4. LAST，表示这是一条记录的最后一部分。

## log日志Writer类
log日志写相对简单，把数据按记录的格式封装好，再写入文件即可。成员变量有：
```
  WritableFile* dest_;//log日志文件封装类
  int block_offset_;       // 块内偏移量用于指定写地址
```
添加记录函数：
```
Status Writer::AddRecord(const Slice& slice) {
  const char* ptr = slice.data();//添加记录数据
  size_t left = slice.size();//记录数据长度

  Status s;
  bool begin = true;
  do {
    const int leftover = kBlockSize - block_offset_;//当前块剩余容量
    assert(leftover >= 0);
    if (leftover < kHeaderSize) {//如果剩余容量小于记录头长度（7kb）
	//用00填充
      if (leftover > 0) {
        assert(kHeaderSize == 7);
        dest_->Append(Slice("\x00\x00\x00\x00\x00\x00", leftover));
      }
      block_offset_ = 0;//开始写一个新块，块内偏移就为0了。
    }

    assert(kBlockSize - block_offset_ - kHeaderSize >= 0);
    //当前块除了记录头还有剩余空间
    const size_t avail = kBlockSize - block_offset_ - kHeaderSize;//可用的空间
    const size_t fragment_length = (left < avail) ? left : avail;
    //判断当前块能否容下当前记录
    RecordType type;
    const bool end = (left == fragment_length);//判断是否是记录的最后一部分
    if (begin && end) {
      type = kFullType;//完整块
    } else if (begin) {
      type = kFirstType;//记录第一块
    } else if (end) {
      type = kLastType;//最后一块
    } else {
      type = kMiddleType;//记录中间块
    }

    s = EmitPhysicalRecord(type, ptr, fragment_length);//将fragment_length长度记录写入文件
    ptr += fragment_length;//指针向后移动frament_length个字节
    left -= fragment_length;//记录剩余长度
    begin = false;
  } while (s.ok() && left > 0);
  return s;
}

Status Writer::EmitPhysicalRecord(RecordType t, const char* ptr, size_t n) {
  assert(n <= 0xffff);  
  assert(block_offset_ + kHeaderSize + n <= kBlockSize);

  // 封装好记录头checksum7+length2+flag1
  char buf[kHeaderSize];
  buf[4] = static_cast<char>(n & 0xff);
  buf[5] = static_cast<char>(n >> 8);
  buf[6] = static_cast<char>(t);

  // 用crc填充buf前四个字节
  uint32_t crc = crc32c::Extend(type_crc_[t], ptr, n);
  crc = crc32c::Mask(crc);                 // Adjust for storage
  EncodeFixed32(buf, crc);

  // 将记录头写入缓存
  Status s = dest_->Append(Slice(buf, kHeaderSize));
  if (s.ok()) {
    s = dest_->Append(Slice(ptr, n));//将记录内容写入缓存
    if (s.ok()) {
      s = dest_->Flush();//将缓存的数据刷新进内核。
    }
  }
  block_offset_ += kHeaderSize + n;//更新块内偏移量
  return s;
}
```
log写文件分析就结束了。接下来分析log文件读取，读取相对较难。

## log文件Reader类
我们先来看下Reader类的成员变量：
```
 SequentialFile* const file_;//读取文件封装类
  Reporter* const reporter_;//报告错误类
  bool const checksum_;//是否要进行CRC验证
  char* const backing_store_;//读取是存储备份
  Slice buffer_;//一次性读取一个块，而且用于定位lsat_record_offset_
  bool eof_;   // 是否是最后一次读

  // 上条记录的偏移量
  uint64_t last_record_offset_;
  // 当前块结尾在log文件的偏移量
  uint64_t end_of_buffer_offset_;

  // 开始查找的起始地址
  uint64_t const initial_offset_;
```

读取文件函数：
```
bool Reader::ReadRecord(Slice* record, std::string* scratch) {
  if (last_record_offset_ < initial_offset_) {
    if (!SkipToInitialBlock()) {
      return false;
    }
  }

  scratch->clear();
  record->clear();
  bool in_fragmented_record = false;//上条记录是否为完整记录
  uint64_t prospective_record_offset = 0;//当前读取记录的偏移量

  Slice fragment;
  while (true) {
    //当前记录的起始地址
    uint64_t physical_record_offset = end_of_buffer_offset_ - buffer_.size();
    //读取当前记录
    const unsigned int record_type = ReadPhysicalRecord(&fragment);
    switch (record_type) {
      case kFullType:
        if (in_fragmented_record) {
          // 完整记录，直接读取即可。
          if (scratch->empty()) {
            in_fragmented_record = false;
          } else {
            ReportCorruption(scratch->size(), "partial record without end(1)");
          }
        }
        prospective_record_offset = physical_record_offset;
        scratch->clear();
        *record = fragment;
        last_record_offset_ = prospective_record_offset;//对于下一条记录而言，这偏移量就是上条记录的偏移量，
//也就是这条记录的偏移量
        return true;

      case kFirstType:
        if (in_fragmented_record) {
          // 如果是一条记录的第一部分
          if (scratch->empty()) {
            in_fragmented_record = false;
          } else {
            ReportCorruption(scratch->size(), "partial record without end(2)");
          }
        }
        prospective_record_offset = physical_record_offset;
        scratch->assign(fragment.data(), fragment.size());//把第一部分的数据添加进scratch
        in_fragmented_record = true;//下一条记录就是属于当前记录的一部分
        break;

      case kMiddleType:
        if (!in_fragmented_record) {
          ReportCorruption(fragment.size(),
                           "missing start of fragmented record(1)");
        } else {
          scratch->append(fragment.data(), fragment.size());//将当前记录添加进scratch
        }
        break;

      case kLastType:
        if (!in_fragmented_record) {
          ReportCorruption(fragment.size(),
                           "missing start of fragmented record(2)");
        } else {
          scratch->append(fragment.data(), fragment.size());//当前记录最后部分添加进scratch
          *record = Slice(*scratch);//给record赋值，即记录的内容
          last_record_offset_ = prospective_record_offset;//指向当前记录的起始地址
          return true;
        }
        break;

      case kEof:
        if (in_fragmented_record) {
          // This can be caused by the writer dying immediately after
          // writing a physical record but before completing the next; don't
          // treat it as a corruption, just ignore the entire logical record.
          scratch->clear();
        }
        return false;

      case kBadRecord:
        if (in_fragmented_record) {
          ReportCorruption(scratch->size(), "error in middle of record");
          in_fragmented_record = false;
          scratch->clear();
        }
        break;

      default: {
        char buf[40];
        snprintf(buf, sizeof(buf), "unknown record type %u", record_type);
        ReportCorruption(
            (fragment.size() + (in_fragmented_record ? scratch->size() : 0)),
            buf);
        in_fragmented_record = false;
        scratch->clear();
        break;
      }
    }
  }
  return false;
}
```
从文件读取记录的函数如下:
```
unsigned int Reader::ReadPhysicalRecord(Slice* result) {
  while (true) {
    if (buffer_.size() < kHeaderSize) {
      if (!eof_) {
        // 因为不是结尾，说明上次读取的是一整个块，现在这个块只剩下补充的0，跳过即可。
        buffer_.clear();
 	//读取一个新块
        Status status = file_->Read(kBlockSize, &buffer_, backing_store_);
        end_of_buffer_offset_ += buffer_.size();//缓存块偏移量指向这个块结尾。
        if (!status.ok()) {
          buffer_.clear();
          ReportDrop(kBlockSize, status);
          eof_ = true;
          return kEof;//如果读取失败，返回结尾
        } else if (buffer_.size() < kBlockSize) {
          eof_ = true;//读取成功，但是读取记录小于头，实际大小应该是0，到达文件结尾
        }
        continue;
      } else {
        buffer_.clear();
        return kEof;
      }
    }

    // 解析记录头
    const char* header = buffer_.data();
    const uint32_t a = static_cast<uint32_t>(header[4]) & 0xff;
    const uint32_t b = static_cast<uint32_t>(header[5]) & 0xff;
    const unsigned int type = header[6];//记录类型
    const uint32_t length = a | (b << 8);//记录长度
    if (kHeaderSize + length > buffer_.size()) {
      size_t drop_size = buffer_.size();
      buffer_.clear();
      if (!eof_) {
        ReportCorruption(drop_size, "bad record length");
        return kBadRecord;
      }
      // If the end of the file has been reached without reading |length| bytes
      // of payload, assume the writer died in the middle of writing the record.
      // Don't report a corruption.
      return kEof;
    }

    if (type == kZeroType && length == 0) {
      // Skip zero length record without reporting any drops since
      // such records are produced by the mmap based writing code in
      // env_posix.cc that preallocates file regions.
      buffer_.clear();
      return kBadRecord;
    }

    // Check crc
    if (checksum_) {
      uint32_t expected_crc = crc32c::Unmask(DecodeFixed32(header));
      uint32_t actual_crc = crc32c::Value(header + 6, 1 + length);
      if (actual_crc != expected_crc) {
        // Drop the rest of the buffer since "length" itself may have
        // been corrupted and if we trust it, we could find some
        // fragment of a real log record that just happens to look
        // like a valid log record.
        size_t drop_size = buffer_.size();
        buffer_.clear();
        ReportCorruption(drop_size, "checksum mismatch");
        return kBadRecord;
      }
    }

    buffer_.remove_prefix(kHeaderSize + length);//buffer_是一块的长度，当读取结束一条记录时
//buffer_指向内容的指针向前移动KheaderSize+length，即下一条记录的起始地址

    // 跳过初始地址之前的记录
    if (end_of_buffer_offset_ - buffer_.size() - kHeaderSize - length <
        initial_offset_) {
      result->clear();
      return kBadRecord;
    }

    *result = Slice(header + kHeaderSize, length);//获取记录内容部分
    return type;
  }
}
```
读写log文件主要是要熟悉log文件的记录模型和文件的偏移量，这样当按格式，一个字节一个字节写入log文件是时，Reader类才能精确地一个一个字节从文件读出。我上两张图帮助理解：
![log文件读取记录](http://7xjnip.com1.z0.glb.clouddn.com/luodw--log1.jpg "")
这张图假设读取Record C的第一部分，因为在第一块内，所以end_of_buffer_offset_指向第一个块的最后一个字节，last_record_offset\_指向Record B，buffer\_的长度为B记录第一部分长度。当第一部分读取结束时，此时，因为第一块已经读取结束，所以从新从文件读取一个块存如buffer_，end_of_buffer_offset_指向第二个块的最后一个字节。因为buffer_.size()=一个块的容量，所以接下来读取C记录第二部分的偏移量为Block2的首地址。下图展示了读取RecordB之后图示:
![log文件读取记录](http://7xjnip.com1.z0.glb.clouddn.com/luodw--log2.jpg "")

至此，log文件读取结束，也就是leveldb第二大组件。leveldb第三大组件为sst文件，接下来几篇文章讲解。






