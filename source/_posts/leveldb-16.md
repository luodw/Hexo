title: leveldb源码分析之version、version_edit和version_set
date: 2015-10-31 16:39:54
tags:
- leveldb
- version
- version_edit
- version_set
categories:
- leveldb
toc: true

---

今天这篇文章主要讲解我之前很恐惧的leveldb版本控制，version,version_edit和version_set，主要原因吧，还是这三个是紧密联系在一起的，代码量大。这篇文章讲下我自己对版本控制的一知半解，也算自我总结。

# version_edit版本编辑
version_edit这个类主要是两个版本之间的差量。形象点说，就是当前版本+version_edit即可成为新的版本，version0+version_edit=version1。对于leveldb来说，一个版本包括所有数据文件，log文件，manifest_file，current文件，LOG文件和LOCK文件，而文件是由文件编号来标识的，所以对于一个版本来说，会变化的变量有log文件编号，序列号，文件编号，所以version_edt主要就是来操作这个变量以及文件的增删，定义如下,先列出成员变量:
```
 private:
  friend class VersionSet;
  //定义删除文件集合，<层次，文件编号>
  typedef std::set< std::pair<int, uint64_t> > DeletedFileSet;

  std::string comparator_;//比较器名称
  uint64_t log_number_;//日志文件编号
  uint64_t prev_log_number_;//上一个日志文件编号
  uint64_t next_file_number_;//下一个文件编号
  SequenceNumber last_sequence_;//上一个序列号
  bool has_comparator_;//是否有比较器
  bool has_log_number_;
  bool has_prev_log_number_;
  bool has_next_file_number_;
  bool has_last_sequence_;
  //压缩点<层次，InternalKey键>
  std::vector< std::pair<int, InternalKey> > compact_pointers_;
  //删除文件集合
  DeletedFileSet deleted_files_;
  //新添加的文件集合
  std::vector< std::pair<int, FileMetaData> > new_files_;
```
这个version_edit保存了版本可能会变化的变量，这个类提供的接口包括设置这些变量的接口set方法，以及将上述成员序列化和反序列化的方法。当version\_edit序列化时，图片来自博客[sparkliang的专栏](http://blog.csdn.net/sparkliang/article/details/8776583 "")格式如下:![manifest文件格式](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区\_023.png "");

图中的数字表示为:
```
enum Tag {
  kComparator           = 1,
  kLogNumber            = 2,
  kNextFileNumber       = 3,
  kLastSequence         = 4,
  kCompactPointer       = 5,
  kDeletedFile          = 6,
  kNewFile              = 7,
  // 8 was used for large value refs
  kPrevLogNumber        = 9
};
```
因为version_edit序列化之后，会保存在manifest文件中，所以这张图既是version_edit序列化为字符串时的格式，也是manifest文件格式。

接下来看下如何序列化这个version_edit:
```
void VersionEdit::EncodeTo(std::string* dst) const {
  //将比较器的标识和名称放入序列化字符串中
  if (has_comparator_) {
    PutVarint32(dst, kComparator);
    PutLengthPrefixedSlice(dst, comparator_);
  }
  //将日志文件编号的标识和名称放入序列化字符串中
  if (has_log_number_) {
    PutVarint32(dst, kLogNumber);
    PutVarint64(dst, log_number_);
  }
  //将前一个日志的标识和名称放入序列化字符串中
  if (has_prev_log_number_) {
    PutVarint32(dst, kPrevLogNumber);
    PutVarint64(dst, prev_log_number_);
  }
  //将下一个文件的标识和名称放入序列化字符串中
  if (has_next_file_number_) {
    PutVarint32(dst, kNextFileNumber);
    PutVarint64(dst, next_file_number_);
  }
  //将上一个序列号的标识和名称放入序列化字符串中
  if (has_last_sequence_) {
    PutVarint32(dst, kLastSequence);
    PutVarint64(dst, last_sequence_);
  }
  //将每个压缩点的标识，层次和InternalKey放入序列化字符串
  for (size_t i = 0; i < compact_pointers_.size(); i++) {
    PutVarint32(dst, kCompactPointer);
    PutVarint32(dst, compact_pointers_[i].first);  // level
    PutLengthPrefixedSlice(dst, compact_pointers_[i].second.Encode());
  }
  //将每个删除文件的标识,层次，文件编号放入序列化字符串中
  for (DeletedFileSet::const_iterator iter = deleted_files_.begin();
       iter != deleted_files_.end();
       ++iter) {
    PutVarint32(dst, kDeletedFile);
    PutVarint32(dst, iter->first);   // level
    PutVarint64(dst, iter->second);  // file number
  }
  //将增加的字符串的标识以及f属性添加进序列化字符串中
  for (size_t i = 0; i < new_files_.size(); i++) {
    const FileMetaData& f = new_files_[i].second;
    PutVarint32(dst, kNewFile);
    PutVarint32(dst, new_files_[i].first);  // level
    PutVarint64(dst, f.number);
    PutVarint64(dst, f.file_size);
    PutLengthPrefixedSlice(dst, f.smallest.Encode());
    PutLengthPrefixedSlice(dst, f.largest.Encode());
  }
}
```
上述这个函数就是将version_edit序列化成字符串，然后存入manifest文件中，接下来看下，如何反序列化，将manifest反序列化为version_edit。
```
Status VersionEdit::DecodeFrom(const Slice& src) {
  Clear();//先清空原有数据
  Slice input = src;
  const char* msg = NULL;
  uint32_t tag;

  // 为了解析，临时定义的存储变量
  int level;
  uint64_t number;
  FileMetaData f;
  Slice str;
  InternalKey key;

  while (msg == NULL && GetVarint32(&input, &tag)) {
    switch (tag) {//根据tag，也就是标识，解析不同的变量
      case kComparator:
        if (GetLengthPrefixedSlice(&input, &str)) {
          comparator_ = str.ToString();
          has_comparator_ = true;
        } else {
          msg = "comparator name";
        }
        break;

      case kLogNumber:
        if (GetVarint64(&input, &log_number_)) {
          has_log_number_ = true;
        } else {
          msg = "log number";
        }
        break;

      case kPrevLogNumber:
        if (GetVarint64(&input, &prev_log_number_)) {
          has_prev_log_number_ = true;
        } else {
          msg = "previous log number";
        }
        break;

      case kNextFileNumber:
        if (GetVarint64(&input, &next_file_number_)) {
          has_next_file_number_ = true;
        } else {
          msg = "next file number";
        }
        break;

      case kLastSequence:
        if (GetVarint64(&input, &last_sequence_)) {
          has_last_sequence_ = true;
        } else {
          msg = "last sequence number";
        }
        break;

      case kCompactPointer:
        if (GetLevel(&input, &level) &&
            GetInternalKey(&input, &key)) {
          compact_pointers_.push_back(std::make_pair(level, key));
        } else {
          msg = "compaction pointer";
        }
        break;

      case kDeletedFile:
        if (GetLevel(&input, &level) &&
            GetVarint64(&input, &number)) {
          deleted_files_.insert(std::make_pair(level, number));
        } else {
          msg = "deleted file";
        }
        break;

      case kNewFile:
        if (GetLevel(&input, &level) &&
            GetVarint64(&input, &f.number) &&
            GetVarint64(&input, &f.file_size) &&
            GetInternalKey(&input, &f.smallest) &&
            GetInternalKey(&input, &f.largest)) {
          new_files_.push_back(std::make_pair(level, f));
        } else {
          msg = "new-file entry";
        }
        break;

      default:
        msg = "unknown tag";
        break;
    }
  }

  if (msg == NULL && !input.empty()) {
    msg = "invalid tag";
  }

  Status result;
  if (msg != NULL) {
    result = Status::Corruption("VersionEdit", msg);
  }
  return result;
}
```
这个函数也很简单，就是根据不同的标识，解析出不同的变量，最后再判断有没出错，如果没出错，则返回空的status，错误，则返回错误状态。

# Version版本类

这个类主要功能，首先是提供了在当前版本搜索键值的Get方法，其次是为上层调用提供了收集当前版本所有文件的迭代器，最后是为合并文件提供了判断键值范围与文件是否有交集的辅助函数。

接下来先看下Version提供的收集文件迭代器的方法,对于第0层，直接从Table_cache中获取即可，因为当初每campaction时，都将文件添加进table_cache缓存；对于大于第0层的文件，创建是两层迭代器，后面分析，为了分析两层迭代器，需要先介绍下第一层迭代器，也就是迭代某一层文件的迭代器
```
class Version::LevelFileNumIterator : public Iterator {
 public:
  LevelFileNumIterator(const InternalKeyComparator& icmp,
                       const std::vector<FileMetaData*>* flist)
      : icmp_(icmp),//比较器
        flist_(flist),//某一层文件集合
        index_(flist->size()) { //某一层文件的编号，等于文件个数时，即为无效 
  }
  virtual bool Valid() const {
    return index_ < flist_->size();
  }
  virtual void Seek(const Slice& target) {
    //在这层查找键值大于等于target的文件索引
    index_ = FindFile(icmp_, *flist_, target);
  }
  virtual void SeekToFirst() { index_ = 0; }
  virtual void SeekToLast() {
    index_ = flist_->empty() ? 0 : flist_->size() - 1;
  }
  virtual void Next() {
    assert(Valid());
    index_++;
  }
  virtual void Prev() {
    assert(Valid());
    if (index_ == 0) {
      index_ = flist_->size();  // Marks as invalid
    } else {
      index_--;
    }
  }
  Slice key() const {
    assert(Valid());
    //返回大于等于target文件的最大键值
    return (*flist_)[index_]->largest.Encode();
  }
  Slice value() const {
    assert(Valid());//返回这个文件的文件编号和大小封装成的字符串
    EncodeFixed64(value_buf_, (*flist_)[index_]->number);
    EncodeFixed64(value_buf_+8, (*flist_)[index_]->file_size);
    return Slice(value_buf_, sizeof(value_buf_));
  }
  virtual Status status() const { return Status::OK(); }
 private:
  const InternalKeyComparator icmp_;
  const std::vector<FileMetaData*>* const flist_;
  uint32_t index_;

  // Backing store for value().  Holds the file number and size.
  mutable char value_buf_[16];
};
```
上述这个迭代器就是迭代某一层内所有的文件，第二层迭代器就是迭代某一层某一个文件的迭代器，和Table的双层迭代器有点像，Table双层迭代器是首先迭代文件块，然后块内迭代器。下面是Version提供添加所有文件迭代器的接口
```
void Version::AddIterators(const ReadOptions& options,
                           std::vector<Iterator*>* iters) {
  // Merge all level zero files together since they may overlap
  for (size_t i = 0; i < files_[0].size(); i++) {
    iters->push_back(
        vset_->table_cache_->NewIterator(
            options, files_[0][i]->number, files_[0][i]->file_size));
  }

  // For levels > 0, we can use a concatenating iterator that sequentially
  // walks through the non-overlapping files in the level, opening them
  // lazily.
  for (int level = 1; level < config::kNumLevels; level++) {
    if (!files_[level].empty()) {
      iters->push_back(NewConcatenatingIterator(options, level));
    }
  }
}
```

好，接来看下创建两层迭代器的方法NewConcatenatingIterator
```
Iterator* Version::NewConcatenatingIterator(const ReadOptions& options,
                                            int level) const {
  return NewTwoLevelIterator(
      new LevelFileNumIterator(vset_->icmp_, &files_[level]),
      &GetFileIterator, vset_->table_cache_, options);
}

//传入的函数指针，就是为了将文件元数据添加进Table_cache
static Iterator* GetFileIterator(void* arg,
                                 const ReadOptions& options,
                                 const Slice& file_value) {
  TableCache* cache = reinterpret_cast<TableCache*>(arg);
  if (file_value.size() != 16) {
    return NewErrorIterator(
        Status::Corruption("FileReader invoked with unexpected value"));
  } else {
    return cache->NewIterator(options,
                              DecodeFixed64(file_value.data()),
                              DecodeFixed64(file_value.data() + 8));
  }
}
```
这个两层迭代器不分析了，因为之前在Table_cache有分析过。内部调用大概通过LevelFileNumIterator先迭代到具体的文件，然后再调用GetFileIterator回调函数创建创建这个文件的Table_cache迭代器，并添加进Table_cache。

leveldb这个两层迭代器设计非常巧妙，因为刚生成这两层迭代器时，迭代器不会将任何文件载入内存，而是当查询某个键值时，才会把具体的文件元数据添加进Table_cache，这中用法叫做open-lazily,即推迟打开文件。

接下来，看下Get函数，就是根据提供的键值，查询对应的value。原理如下:
1. 对于第0层文件，因为这些文件有可能相交，所以要迭代所有文件，把和查询键值有交集的文件添加进一个临时的集合中。
2. 对于第1层以及以上文件，因为这些文件不相交，所以只要二分查找文件即可。
3. 根据找到的文件，调用table_cache->Get方法获取具体的value值。对于第0层文件，因为获取到查询的文件不止一个，所以跟新状态保存的是第一个查找到的文件。
4. 将找到的值存入传进的参数。

代码偏长，我将重要片段贴出来:
```
      Saver saver;
      saver.state = kNotFound;
      saver.ucmp = ucmp;
      saver.user_key = user_key;
      saver.value = value;
      s = vset_->table_cache_->Get(options, f->number, f->file_size,
                                   ikey, &saver, SaveValue);
```
这个Saver是定义的一个结构体，用于保存Get函数内部得到的值。我们来看下这个回调函数，也就是用于保存value值的函数:
```
static void SaveValue(void* arg, const Slice& ikey, const Slice& v) {
  Saver* s = reinterpret_cast<Saver*>(arg);
  ParsedInternalKey parsed_key;
  if (!ParseInternalKey(ikey, &parsed_key)) {
    s->state = kCorrupt;
  } else {
    if (s->ucmp->Compare(parsed_key.user_key, s->user_key) == 0) {
      s->state = (parsed_key.type == kTypeValue) ? kFound : kDeleted;
      if (s->state == kFound) {
        s->value->assign(v.data(), v.size());
      }
    }
  }
}

```
这个函数是在Table::InternalGet函数中调用，此时传进函数的v已经是查找到的value值，根据键值对的类型，设置不同的state状态，如果是kDeleted，则value值为空，如果是kFound，将v赋值给value。第一次看这源码可能有个抑或，因为没有给version->Get函数传递的value赋值，version->Get函数返回时，可以从Value中获取值？这是因为value是一个指针，saver.value=value是指针赋值，也就是说这两个指针指向同一个地方，所以一个赋值，也就是对另一个赋值了。

Version其他函数都是和Campaction相关的，暂时不说了。接下来看下Version_set。

# Version_set版本集合类

Version_set这个类不只是简单的Version集合，还操作着和版本变化的一些函数，例如将version_edit应用到新的版本，将新版本设为当前版本等等。

先来看下成员变量:
```
  Env* const env_;//操作系统封装
  const std::string dbname_;//数据库名称
  const Options* const options_;//选项配置
  TableCache* const table_cache_;//用于version调用get时调用
  const InternalKeyComparator icmp_;//以下6个都是版本可变的
  uint64_t next_file_number_;
  uint64_t manifest_file_number_;
  uint64_t last_sequence_;
  uint64_t log_number_;
  uint64_t prev_log_number_;  // 0 or backing store for memtable being compacted

  // Opened lazily
  WritableFile* descriptor_file_;//manifest文件
  log::Writer* descriptor_log_;//将Version_edit写进manifest
  Version dummy_versions_;  // 环形双向链表的表头
  Version* current_;        //当前版本界定 == dummy_versions_.prev_

  // 每一层下次compaction的键值，空值或者一个有效的InternalKey
  std::string compact_pointer_[config::kNumLevels];
```
## Builder类

接下来先来看下Version_set的内部类Builder，这个类用于将manifest文件内容添加进当前版本，并将当前版本添加进版本链表，然后成员变量如下:
```
class VersionSet::Builder {
 private:
  // Helper to sort by v->files_[file_number].smallest
  struct BySmallestKey {
    const InternalKeyComparator* internal_comparator;

    bool operator()(FileMetaData* f1, FileMetaData* f2) const {
      int r = internal_comparator->Compare(f1->smallest, f2->smallest);
      if (r != 0) {
        return (r < 0);
      } else {
        // Break ties by file number
        return (f1->number < f2->number);
      }
    }
  };
//定义一个用于排序文件元数据的函数对象，先是按最小键值排序，如果最小键值相等，就按文件编号从小到大排序。

  typedef std::set<FileMetaData*, BySmallestKey> FileSet;
  //定义文件集合类型，集合从小到大排序
  struct LevelState {
    std::set<uint64_t> deleted_files;
    FileSet* added_files;
  };

  VersionSet* vset_;//所属的版本链表
  Version* base_;//当前版本
  //每一层文件状态，添加或删除文件
  LevelState levels_[config::kNumLevels];
```
当打开一个已存在的数据库时，此时需要将磁盘的文件信息恢复到一个版本，也就是将manifest内的信息包装成Version_edit，并应用到当前版本，这时就需要调用Builder->Apply方法，这方法先是将edit里的信息解析到Builder中，接着再调用Builder->Saveto保存到当前版本中。先来看下Builder->Apply方法
```
void Apply(VersionEdit* edit) {
    // 将每层compaction节点添加进version_set
    for (size_t i = 0; i < edit->compact_pointers_.size(); i++) {
      const int level = edit->compact_pointers_[i].first;
      vset_->compact_pointer_[level] =
          edit->compact_pointers_[i].second.Encode().ToString();
    }

    // 将删除文件添加进Builder
    const VersionEdit::DeletedFileSet& del = edit->deleted_files_;
    for (VersionEdit::DeletedFileSet::const_iterator iter = del.begin();
         iter != del.end();
         ++iter) {
      const int level = iter->first;
      const uint64_t number = iter->second;
      levels_[level].deleted_files.insert(number);
    }

    // 将增加的文件添加进Builder
    for (size_t i = 0; i < edit->new_files_.size(); i++) {
      const int level = edit->new_files_[i].first;
      FileMetaData* f = new FileMetaData(edit->new_files_[i].second);
      f->refs = 1;
      f->allowed_seeks = (f->file_size / 16384);
      if (f->allowed_seeks < 100) f->allowed_seeks = 100;

      levels_[level].deleted_files.erase(f->number);
      levels_[level].added_files->insert(f);
    }
  }
```
 f->allowed_seeks 这个是当文件被查询几次之后，需要进行compaction，源码中有注释为何这样计算该值。接来下，看下如何把edit的信息应用到当前版本。

将edit应用到当前版本调用的函数是SaveTo。该函数将上一版本所有文件和新添加的文件按比较器定义的比较方法排序，存储到新版本中。如果是已经在删除文件集合中，则不添加进新版本中。
```
  for (int level = 0; level < config::kNumLevels; level++) {
      // 将新添加的文件和上个版本的文件合并
      // 删除掉deleted集合中的文件，把结果保存在新版本v中
      const std::vector<FileMetaData*>& base_files = base_->files_[level];
      std::vector<FileMetaData*>::const_iterator base_iter = base_files.begin();
      std::vector<FileMetaData*>::const_iterator base_end = base_files.end();
      const FileSet* added = levels_[level].added_files;
      v->files_[level].reserve(base_files.size() + added->size());
      for (FileSet::const_iterator added_iter = added->begin();
           added_iter != added->end();
           ++added_iter) {
        // 这个循环是将比新添加的文件“小“的文件先添加进新版本中
        for (std::vector<FileMetaData*>::const_iterator bpos
                 = std::upper_bound(base_iter, base_end, *added_iter, cmp);
             base_iter != bpos;
             ++base_iter) {
          MaybeAddFile(v, level, *base_iter);
        }
        //将新添加文件添加进新版本中
        MaybeAddFile(v, level, *added_iter);
      }

      // 添加其他文件，其实也就是比新添加文件”大“的文件
      for (; base_iter != base_end; ++base_iter) {
        MaybeAddFile(v, level, *base_iter);
      }
```
删除deleted集合中文件的操作就在MaybeAddFile，这函数名字起的很好，可能添加，因为如果在deleted集合中，则不添加，源码如下；
```
  void MaybeAddFile(Version* v, int level, FileMetaData* f) {
    if (levels_[level].deleted_files.count(f->number) > 0) {
      // 如果文件f在deleted集合中，则啥都不做。
    } else {
      std::vector<FileMetaData*>* files = &v->files_[level];
      if (level > 0 && !files->empty()) {
        // 如果是大于0层的文件，新添加的文件不能和集合中已存在的文件有交集
        assert(vset_->icmp_.Compare((*files)[files->size()-1]->largest,
                                    f->smallest) < 0);
      }
      f->refs++;//文件引用加1
      files->push_back(f);//添加文件
    }
  }
```
## Recover函数

介绍完上述Builder类的成员函数之后，我们来看Recover函数，也就是当打开一个已存在的数据库时，将manifest内的edit信息应用到新建的版本中，然后日志文件恢复就留给dbimpl->Recover函数实现。

VersionSet->Recover方法实现原理如下，
1. 先从Current文件读取目前正在使用的manifest文件；
2. 从manifest文件读取数据，并反序列化为Version_set类；
3. 调用builder.Apply方法，将editcompaction点，增加文件集合，删除文件集合放进builder中，并从将edit内各个文件编号赋值给Version_set相应的变量；
4. 新建一个版本v，将builder中信息应用到这个版本中，然后再将这个版本添加进版本链表中，并设置为当前版本。
5. 最后更新Version_set内的文件编号。

代码偏长，不黏贴了；

## LogAndApply函数

这个函数主要是将edit信息写进manifest文件中，并应用到新版本中。经常在文件合并之后,会出现文件文件添加删除情况,所以需要保存日志以及新生成一个新版.

这个函数原理如下:
1. 将version_set内的文件内的文件编号保存进edit;
2. 新建一个Version,然后调用Builder->apply和Builder->SaveTo方法将edit应用到新版本中.
3. 将edit写进manifest文件中,并更新Current文件,指向最新manifest.
4. 将新版本添加到版本链表中,并设置为当前链表.

先看下前两步源码:
```
 if (edit->has_log_number_) {
    assert(edit->log_number_ >= log_number_);
    assert(edit->log_number_ < next_file_number_);
  } else {
    edit->SetLogNumber(log_number_);
  }

  if (!edit->has_prev_log_number_) {
    edit->SetPrevLogNumber(prev_log_number_);
  }

  edit->SetNextFile(next_file_number_);
  edit->SetLastSequence(last_sequence_);

  Version* v = new Version(this);
  {
    Builder builder(this, current_);
    builder.Apply(edit);
    builder.SaveTo(v);
  }
  Finalize(v);//这个函数主要是用来更新每一层文件合并分数.
```
源码很简单,设置文件编号,将edit应用到新版本中.3,4步代码很简单,就不黏贴出来了.

Version_set类主要功能包括调用当前版本的Get方法和添加迭代器方法,以及从磁盘manifest文件恢复当新版本中,将edit信息写进manifest并应用到当前版本中,其他就和合并相关了,暂时不叙述~
