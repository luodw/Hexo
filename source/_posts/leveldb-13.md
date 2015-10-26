title: leveldb源码分析之Table_cache
date: 2015-10-25 21:11:43
tags:
- leveldb
- table_cache
categories:
- leveldb

---

上篇文章有说到过，leveldb有分为block_cache和table_cache。block_cache主要是用来缓存data_block，减少磁盘IO次数。那table_cache是用来干啥了？

先介绍table_cache的键值对形式，如下图所示：
![table_cache的键值对格式](http://7xjnip.com1.z0.glb.clouddn.com/luodw--Table_cache.jpg "");

key值为sst文件的文件编号，value为这个sst文件的TableAndFile结构体指针，然后这个TableAndFile是由RandomAccessFile指针和Table指针组成。所以从这个TableAndFile指针，就可以获得这个文件的Table指针，随即可以得到这个文件的任何键值对。所以这个缓存有点类似Linux内核中的inode，由indoe就可以获取磁盘的data block。

先看下Table_cache这个类的定义：
```
//成员属性
  Env* const env_;//操作系统封装类
  const std::string dbname_;//数据库名字
  const Options* options_;//配置选项类
  Cache* cache_;//Table_cache类

//构造函数如下:
TableCache::TableCache(const std::string& dbname,
                       const Options* options,
                       int entries)
    : env_(options->env),
      dbname_(dbname),
      options_(options),
      cache_(NewLRUCache(entries)) {//Table_cache默认开启，而且为NewLRUCache
}
```
先介绍下FindTable这个函数:
```
Status TableCache::FindTable(uint64_t file_number, uint64_t file_size,
                             Cache::Handle** handle) {
  Status s;
  char buf[sizeof(file_number)];//定义用于存储文件编号的字符数组
  EncodeFixed64(buf, file_number);//整型编码存储在buf中
  Slice key(buf, sizeof(buf));
  *handle = cache_->Lookup(key);//在Table中查找这个文件编号的handle。
  if (*handle == NULL) {如果在TableCache中没有找到，则要新建一个handle，存储这个文件缓存
    std::string fname = TableFileName(dbname_, file_number);
    RandomAccessFile* file = NULL;
    Table* table = NULL;
    s = env_->NewRandomAccessFile(fname, &file);
    if (!s.ok()) {
      std::string old_fname = SSTTableFileName(dbname_, file_number);
      if (env_->NewRandomAccessFile(old_fname, &file).ok()) {
        s = Status::OK();
      }
    }
    if (s.ok()) {
      s = Table::Open(*options_, file, file_size, &table);//打开这个文件的Table，存储在*table
    }

    if (!s.ok()) {
      assert(table == NULL);
      delete file;
      // We do not cache error results so that if the error is transient,
      // or somebody repairs the file, we recover automatically.
    } else {
      TableAndFile* tf = new TableAndFile;//新建一个TableAndFile
      tf->file = file;
      tf->table = table;
      *handle = cache_->Insert(key, tf, 1, &DeleteEntry);//将这个新的tf存入Table_cache
    }
  }
  return s;
}
```
在Table_cache中插入数据时，也注册了这个handle被删除时执行的回调函数。我来分析下，我觉得挺有意思的。首先来看下cache.cc里面handle删除函数
```
void LRUCache::Erase(const Slice& key, uint32_t hash) {
  MutexLock l(&mutex_);
  LRUHandle* e = table_.Remove(key, hash);//先在哈希表删除这个handle
  if (e != NULL) {
    LRU_Remove(e);//循环双向链表删除这个handle
    Unref(e);//引用数减一，如果本来就等于1，则删除这个节点
  }
}

void LRUCache::Unref(LRUHandle* e) {
  assert(e->refs > 0);
  e->refs--;
  if (e->refs <= 0) {
    usage_ -= e->charge;
    (*e->deleter)(e->key(), e->value);//这就是在table_cache注册的回调函数DeleteEntry
    free(e);
  }
}

static void DeleteEntry(const Slice& key, void* value) {
  TableAndFile* tf = reinterpret_cast<TableAndFile*>(value);
  delete tf->table;//先delete  table
  delete tf->file;//再delete  file
  delete tf;//最后delete tf
}
```
以上就是handle被删除时的回调过程。

接下来，分析下table_cache这个类的迭代器：
```
Iterator* TableCache::NewIterator(const ReadOptions& options,
                                  uint64_t file_number,
                                  uint64_t file_size,
                                  Table** tableptr) {
  if (tableptr != NULL) {
    *tableptr = NULL;
  }

  Cache::Handle* handle = NULL;
  Status s = FindTable(file_number, file_size, &handle);//通过文件编号在缓存中查找文件handle
  if (!s.ok()) {
    return NewErrorIterator(s);
  }

  Table* table = reinterpret_cast<TableAndFile*>(cache_->Value(handle))->table;
  //获取这个这个文件编号的Table
  Iterator* result = table->NewIterator(options);获取这个Table的迭代器
  result->RegisterCleanup(&UnrefEntry, cache_, handle);//注册这个handle删除函数
  if (tableptr != NULL) {
    *tableptr = table;
  }
  return result;
}
```
通过源码可以看出，table_cache的迭代器，本质就是table的迭代器。leveldb迭代器设计帧的很巧妙。从block迭代器->table两层迭代器->table_cache迭代器。最后只有通过table_cache迭代器即可获取需要的数据。我觉得这样的做法就是上层接口很简单。

那什么时候将表格的添加进table_cache呢？

上次分析创建sst文件时，分析到了table_builder，其实还有个BuilderTable函数，在builder.h/.cc文件里。来分析下：
```
Status BuildTable(const std::string& dbname,//数据库名称
                  Env* env,//操作系统封装类
                  const Options& options,//配置选项类
                  TableCache* table_cache,//缓存
                  Iterator* iter,//immemtable迭代器，用来将immemtable数据刷回磁盘
                  FileMetaData* meta) {
  Status s;
  meta->file_size = 0;
  iter->SeekToFirst();

  std::string fname = TableFileName(dbname, meta->number);
  if (iter->Valid()) {
    WritableFile* file;
    s = env->NewWritableFile(fname, &file);创建WritableFile，用于存储memtable数据
    if (!s.ok()) {
      return s;
    }

    TableBuilder* builder = new TableBuilder(options, file);//创建table_builder类，
    meta->smallest.DecodeFrom(iter->key());
    for (; iter->Valid(); iter->Next()) {
      Slice key = iter->key();
      meta->largest.DecodeFrom(key);
      builder->Add(key, iter->value());
    }

    // Finish and check for builder errors
    if (s.ok()) {
      s = builder->Finish();//建表完成
      if (s.ok()) {
        meta->file_size = builder->FileSize();
        assert(meta->file_size > 0);
      }
    } else {
      builder->Abandon();
    }
    delete builder;

    // Finish and check for file errors
    if (s.ok()) {
      s = file->Sync();//文件内容刷回磁盘
    }
    if (s.ok()) {
      s = file->Close();
    }
    delete file;
    file = NULL;

    if (s.ok()) {
      // 这就是将这个文件添加进table_cache了
      Iterator* it = table_cache->NewIterator(ReadOptions(),
                                              meta->number,
                                              meta->file_size);
      s = it->status();
      delete it;
    }
  }

  // Check for input iterator errors
  if (!iter->status().ok()) {
    s = iter->status();
  }

  if (s.ok() && meta->file_size > 0) {
    // Keep it
  } else {
    env->DeleteFile(fname);
  }
  return s;
}
```
所以，没创建一个sst文件时 ，就将这个文件的添加进table_cache中，这是有理由的，因为新创建的文件，也必定是最新的，所以在一定程度上可能马上就被要使用到。因为查询键值对时，就是从level0文件开始查询的，也就是最新的文件。

到这边，leveldb三大组件都分析结束了。最后还剩版本控制，db实现类。两个庞然大物，后面再慢慢分析了。
