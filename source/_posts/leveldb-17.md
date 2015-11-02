title: leveldb源码分析之leveldb执行过程
date: 2015-11-01 12:34:10
tags:
- leveldb
categories:
- leveldb
toc: true

---
经过一个月的源码阅读,leveldb源码除了compaction,我都看完了.今天这篇文章,想大概介绍下leveldb执行流程,包括打开数据库,插入数据,读取数据,读取快照等等.那就先从打开数据开始.

# 打开数据库open函数

leveldb打开数据库分两种情况,首先是数据库不存在情况下,则需要新建一个数据;如果是数据存在的情况下,则需要从数据库恢复数据等.接下来讨论下:

首先是open函数:
```
Status DB::Open(const Options& options, const std::string& dbname,
                DB** dbptr) {
  *dbptr = NULL;

  DBImpl* impl = new DBImpl(options, dbname);//new一个DB实现类
  impl->mutex_.Lock();
  VersionEdit edit;
  Status s = impl->Recover(&edit); // 这个函数处理的就是判断数据库是否存在
  //以及从磁盘恢复数据
  if (s.ok()) {
    uint64_t new_log_number = impl->versions_->NewFileNumber();
    WritableFile* lfile;
    //新生成一个manifest文件
    s = options.env->NewWritableFile(LogFileName(dbname, new_log_number),
                                     &lfile);
    if (s.ok()) {
      edit.SetLogNumber(new_log_number);//设置新的manifest文件编号,因为
    //impl->Recover函数改变了new_log_number
      impl->logfile_ = lfile;
      impl->logfile_number_ = new_log_number;
      impl->log_ = new log::Writer(lfile);
      //将磁盘数据恢复到内存之后又做了些改变重新写回磁盘,并设置当前版本
      s = impl->versions_->LogAndApply(&edit, &impl->mutex_);
    }
    if (s.ok()) {
      impl->DeleteObsoleteFiles();//删除过期文件,也就是上个版本的文件
      impl->MaybeScheduleCompaction();//可能执行合并
    }
  }
  impl->mutex_.Unlock();
  if (s.ok()) {
    *dbptr = impl;
  } else {
    delete impl;
  }
  return s;
}
```
这个函数,
1. 先是调用impl->Recover函数从磁盘恢复数据库或者新建一个数据库.
2. 接着根据从日志回见恢复到memtable时,可能对log_number,sequence number做出了改变等等,再重新新建一个版本.
3. 最后删除过期文件以及可能执行文件操作

open函数很重要的函数impl->Recover函数执行流程是这样的:
1. 先查找指定的数据库是否存在,如果存在就打开,不存在就新建一个:
```
Status DBImpl::Recover(VersionEdit* edit) {
mutex_.AssertHeld();

  env_->CreateDir(dbname_);
  assert(db_lock_ == NULL);
  //锁住这个数据库目录
  Status s = env_->LockFile(LockFileName(dbname_), &db_lock_);
  if (!s.ok()) {
    return s;
  }
  //判断文件是否存在
  if (!env_->FileExists(CurrentFileName(dbname_))) {
    if (options_.create_if_missing) {//不存在,且设置了create_if_missing=true,则新建一个
      s = NewDB();
      if (!s.ok()) {
        return s;
      }
    } else {
      return Status::InvalidArgument(
          dbname_, "does not exist (create_if_missing is false)");
    }
  } else {
    if (options_.error_if_exists) {//如果存在,且设置error_if_exists,则报错
      return Status::InvalidArgument(
          dbname_, "exists (error_if_exists is true)");
    }
  }
```
这函数中出现的NewDB(),其实是新建一个初始化文件编号的Version_set,然后写进第一个manifest文件中.
```
Status DBImpl::NewDB() {
  VersionEdit new_db;
  new_db.SetComparatorName(user_comparator()->Name());
  new_db.SetLogNumber(0);
  new_db.SetNextFile(2);
  new_db.SetLastSequence(0);

  const std::string manifest = DescriptorFileName(dbname_, 1);
  WritableFile* file;
  Status s = env_->NewWritableFile(manifest, &file);
  if (!s.ok()) {
    return s;
  }
  {
    log::Writer log(file);
    std::string record;
    new_db.EncodeTo(&record);
    s = log.AddRecord(record);
    if (s.ok()) {
      s = file->Close();
    }
  }
  delete file;
  if (s.ok()) {
    // Make "CURRENT" file that points to the new manifest file.
    s = SetCurrentFile(env_, dbname_, 1);
  } else {
    env_->DeleteFile(manifest);
  }
  return s;
}
```
这样的好处就是,数据库存在和不存在都可以执行执行version_set->Recover函数来初始化数据库.都是从manifest文件恢复版本信息.

2. 当初始化版本信息之后,接来就是将log文件的数据恢复到memtable中,收集日志文件,然后按日志文件编号排序,最后调用RecoverLogFile恢复到memtable.
```
    std::sort(logs.begin(), logs.end());
    for (size_t i = 0; i < logs.size(); i++) {
      s = RecoverLogFile(logs[i], edit, &max_sequence);
      //因为RecoverLogFile这个函数会改变版本的一些属性,所以需要从新
      //设定文件编号
      versions_->MarkFileNumberUsed(logs[i]);
    }
```
RecoverLogFile这个函数偏长,我就不粘代码了,大概执行流程:
+ 先从log文件将所有记录读取出来,并调用WriteBatchInternal::SetContents方法,将记录存入WriteBatch中;
+ 如果mem为空,则创建一个memtable
+ 调用WriteBatchInternal::InertInto方法,将记录插入memtable,更新最大序列号
+ 如果memtable长度大于预先设定的最大值,就执行一次合并.

3. 当从log文件恢复数据到memtable之后,最后再更新一次版本信息.因为之前的步骤中改变了sequence number以及log number等等,所以需要将这个版本的edit写进manifest中,以及重新生成一个新的版本.

4. 最后删除过期的文件,例如上个版本的log文件等,以及可能执行的合并操作.

DB::OPEN函数执行结束之后,*dbptr保存了新创建的DBImpl对象,用于调用input,delete,write,get等操作.

# DB的析构操作

删除数据库时,主要是把数据库中堆中分配的内存析构,memtable,version_set,table_cache等等.析构时,要先判断后台的合并操作有没结束,如果没有结束,必须等待信号通知后台操作结束了,才可析构
```
DBImpl::~DBImpl() {
  // 等待后台合并操作完成
  mutex_.Lock();
  shutting_down_.Release_Store(this);  // Any non-NULL value is ok
  while (bg_compaction_scheduled_) {
    bg_cv_.Wait();
  }
  mutex_.Unlock();

  if (db_lock_ != NULL) {
    env_->UnlockFile(db_lock_);
  }

  delete versions_;
  if (mem_ != NULL) mem_->Unref();
  if (imm_ != NULL) imm_->Unref();
  delete tmp_batch_;
  delete log_;
  delete logfile_;
  delete table_cache_;

  if (owns_info_log_) {
    delete options_.info_log;
  }
  if (owns_cache_) {
    delete options_.block_cache;
  }
}
```

之前在WriteBatch中已经分析过[数据库写入操作](http://luodw.cc/2015/10/30/leveldb-14/ ""),
即db->Put,db->delete,db->Write函数调用.接来下分析下数据库db->Get操作.

# Get操作

leveldb的Get操作,有以下几个几个步骤:
1. 先判断ReadOptions里是否设置快照,如果设置了,就用ReadOptions里的快照,如果没设置,则建立当前时间点的快照.
2. 首先从memtable中查询数据,如果memtable里有需要的数据,则直接返回.如果没有,则到第3步;
3. 从immemtable中查询,如果immemtable中查到了,则直接返回,否则到第4步;
4. 从各层sst文件中查询,调用当前版本的Get方法即可.

主要代码如下;
```
  {
    mutex_.Unlock();
    // First look in the memtable, then in the immutable memtable (if any).
    LookupKey lkey(key, snapshot);
    if (mem->Get(lkey, value, &s)) {
      // Done
    } else if (imm != NULL && imm->Get(lkey, value, &s)) {
      // Done
    } else {
      s = current->Get(options, lkey, value, &stats);
      have_stat_update = true;
    }
    mutex_.Lock();
  }
```

# 获取迭代器操作
先来看下源码:
```
Iterator* DBImpl::NewIterator(const ReadOptions& options) {
  SequenceNumber latest_snapshot;
  uint32_t seed;
  Iterator* iter = NewInternalIterator(options, &latest_snapshot, &seed);
  return NewDBIterator(
      this, user_comparator(), iter,
      (options.snapshot != NULL
       ? reinterpret_cast<const SnapshotImpl*>(options.snapshot)->number_
       : latest_snapshot),
      seed);
}
```
db->DBImpl::NewIterator获取这个leveldb数据库的迭代器,可以用这个迭代器来迭代这个数据库的所有数据,包括在memtable,immemtable和sst文件中的数据库.在这个函数中先调用的是:
```
  Iterator* iter = NewInternalIterator(options, &latest_snapshot, &seed);
```
这个函数将memtable,immemtable和sst文件的所有迭代器汇总到一个MergeIterator中,这也是一种封装,只要通过一个迭代器,即可迭代memtable,immemtable和sst文件中的所有数据.这个迭代器在table/merge里定义,源码容易看得懂.

最后在将MergeIterator封装成DBIterator.DBIterator的定义在db/db_iter.cc文件中.这个DBIterator主要是考虑了删除标记的问题.不一一分析.

leveldb源码分析暂且到此...
