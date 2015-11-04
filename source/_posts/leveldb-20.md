title: leveldb源码分析补充之Compaction
date: 2015-11-04 18:55:14
tags:
- leveldb
- compaction
categories:
- leveldb
toc: true

---

之前打算不看leveldb compaction部分,后来想想,都看了大部分,就差个compaction不看,感觉很不完整,所以还是打算把compaction大概流程写下,后面回头看时,也会有思路

leveldb有两种compaction,一个是minor compaction,就是将immemtable数据写回到磁盘的过程,一种是major compaction,即将某一层某个文件和上一层的几个文件合并的过程.

当向memtable插入数据时,首先会检查是否有空间插入数据,如果有,则继续插入,如果memtable的size达到事先定义好的阈值,则需要进行一次minor compaction;而每进行一次minor compaction时,又要进行一次是否需要major compaction的判断,因为产生一次minor compaction时,可能第0层文件超过8(系统定义,可以自定义),则就需要major compaction了.

在Write函数中,每次插入会进行一次空间需求是否满足的判断;
```
 Status status = MakeRoomForWrite(my_batch == NULL);
```

在MakeRoomForWrite函数中:

1. 先判断是否有后台合并错误,如果有,则啥都不做,如果没有,则执行2;
2. 如果后台没错误,则判断mem_的大小是是否小于事先定义阈值,如果是,则啥都不做返回,继续插入数据,如果大于事先定义的阈值,则需要进行一次合并;
3. 如果imm_不为空,所以后台有线程在执行合并,在此等待;
4. 如果0层文件个数太多,则也需要等待;
5. 如果都不是以上情况,则进程一次合并,调用MaybeScheduleCompaction()函数;

说明下为什么会有第4点,因为没进行一次minor compaction,0层文件个数可能超过事先定义的值,所以会又进行一次major compcation,而这次major compaction,imm_是空的,所以才会有第4条判断.

在MaybeScheduleCompaction()函数中,也需要进行判断;
1. 后台是否有线程在合并,有,则啥都不做,没有的话,执行2
2. 判断数据库是否为删除,后台合并是否出现错误等;
3. 如果上述情况都没问题,就真正调度一个线程执行合并操作.

源码如下;
```
void DBImpl::MaybeScheduleCompaction() {
  mutex_.AssertHeld();
  if (bg_compaction_scheduled_) {
    // Already scheduled
  } else if (shutting_down_.Acquire_Load()) {
    // DB is being deleted; no more background compactions
  } else if (!bg_error_.ok()) {
    // Already got an error; no more changes
  } else if (imm_ == NULL &&
             manual_compaction_ == NULL &&
             !versions_->NeedsCompaction()) {
    // No work to be done
  } else {
    bg_compaction_scheduled_ = true;
    env_->Schedule(&DBImpl::BGWork, this);
  }
}
```

env_->Schedule这个函数是系统封装类,写的一个调用线程的函数,主要功能就是调用BGWork这个函数.BGWork这个函数最终调用的是BackgroundCall()
```
void DBImpl::BGWork(void* db) {
  reinterpret_cast<DBImpl*>(db)->BackgroundCall();
}
```
BackgroundCall()函数源码如下;
```
void DBImpl::BackgroundCall() {
  MutexLock l(&mutex_);
  assert(bg_compaction_scheduled_);
  if (shutting_down_.Acquire_Load()) {
    // No more background work when shutting down.
  } else if (!bg_error_.ok()) {
    // No more background work after a background error.
  } else {
    BackgroundCompaction();
  }

  bg_compaction_scheduled_ = false;

  // Previous compaction may have produced too many files in a level,
  // so reschedule another compaction if needed.
  MaybeScheduleCompaction();
  bg_cv_.SignalAll();
}
```

在这个函数中,如果后台没有其他线程执行且没有后台错误,则执行BackgroundCompaction()函数做后台合并操作.然后将bg_compaction_scheduled_设为false,标识没有后台执行了,其他线程可以进行执行;因为执行一次合并操作之后,可能导致其他层文件个数过多,所以有可能再进行一次合并.最后唤醒所有在MakeRoomForWrite函数中等待的线程.

在BackgroundCompaction函数中,先判断是否为人工合并,即用户调用CompactRange函数.如果是则,则调用人工合并的函数,如果不是,则调用自动合并函数.


1. 对于人工合并,调用的是Version_set::CompactRange函数,
+  先获取在指定层内,与给定键范围[begin,end)有重叠的文件集合,
+  然后根据(大于0层)每一层文件最大的容量,设置合并文件的个数;
+  新建COmpaction类,设置合并文件集合,调用SetupOtherInputs函数;

在SetupOtherInputs函数中,主要是扩展了合并键值范围,其实就是level+1层需要合并的文件,并设置了这次合并的最大键值

2. 对于自动合并,则调用VersionSet::PickCompaction()函数,
+  根据size_compaction或者seek_compaction来设置需要合并的层数以及需要合并的文件
+  调用SetupOtherInputs()函数设置上一层需要合并的文件,设置这层合并最大键值,即 compact_pointer_[level] = largest.Encode().ToString();

设置好compaction对象的level和level+1层需要合并的文件之后,先判断是否只需要移动一个文件即可,如果是,从level移动一个文件到level+1,否则执行真正的合并.真正合并调用的是DoCompactionWork(CompactionState*)函数.

# DoCompactionWork函数

1. 在DoCompactionWork函数中,先将两个集合的文件合并称一个迭代器;
2. 迭代每一个需要合并的文件,删除键值相同,较早时间那个键值对;
3. 删除键类型为kTypeDelete类型的键值;
4. 把除了2,3步涉及的键值之外的键值写入新生成的文件;
5. 判断新生成的文件大小是否大于一定值,如果是,则将这个文件内容刷新到磁盘
6. 等所有键值都写到文件,文件都刷新到磁盘后,调用函数DBImpl::InstallCompactionResults版本更新,因为文件个数,编号产生了变动,所以要新生成一个版本.

# InstallCompactionResults函数

在这个函数里面,主要操作是将用一个edit保存所有需要删除的文件(之前合并的文件),添加合并产生的文件,最后调用Version_set::LogAndApply函数新生成一个版本.


在DoCompactionWork函数结束之后,需要几个扫尾工作.
1. CleanupCompaction(compact); 删除CompactionState这个合并状态对象占有的资源;
2.  c->ReleaseInputs(); 删除上一个版本;
3.  DeleteObsoleteFiles(); 删除磁盘上过期的文件.

leveldb合并就暂且说到这,总结下:
> 当memtable达到一定大小时,会将mem赋值给imm_,然后重新生成一个memtable用于重新插入数据,同时生成一个新的log文件.接着imm_会写入level0文件.如果因为这次写,导致level0文件数量过多,要进行一次磁盘文件合并.
