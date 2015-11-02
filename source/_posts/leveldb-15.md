title: leveldb源码分析之快照SnapShots
date: 2015-10-31 13:59:46
tags:
- levldb
- SnapShots
- 快照
categories:
- leveldb
toc: true

---
之前在学习过程中，也有听过快照这个概念，但是根本不知为何物，更不要说实现原理了。看了leveldb快照实现之后，我对快照这个概念有个简单的认识，因为我百度之后，发现大型数据库的快照的实现和leveldb的快照实现是有区别的。我的理解是，leveldb的快照主要功能是用来读取某个时间点之前的数据，因为leveldb在插入数据时，键值是可以一样的，所以当查询这个键值时，系统返回的是最新的数据，也就是后面插入的数据。但是如果在第二次插入相同键值数据之前，建立一个快照，那么读取这个快照时，读取的就是这个快照时间点之前的数据。

好，接下来，就来分析下leveldb快照的实现原理。

# SnapShots类

leveldb实现快照的原理关键就在于那个sequence number。每当插入一条记录时，都会插入一个独一无二的序列号，而且这个序列号是递增的。所以当插入两条记录的键值一样时，只能通过序列号来区分哪条记录是最新的，因为系统返回的是最新的。而快照SnapShot类的实现原理就是，当调用函数获取一个快照时，就获取目前的sequence number，当读取数据时，只读取小于等于这个序列号的记录，这样就可以读取这个快照时间点之前的数据了。

leveldb实现了保存多个快照的功能，用的是环形双向链表实现。链表保存一个傀儡节点dummy，也就是不存储有用数据的节点。dummy.prev是最新的节点，dummy.next为最“老”的节点。当插入快照时，往dummy之前插入，删除，则删除dummy.next节点。

SnapShots是一个抽象类，在db.h中有声明，真正的快照实现类为SnapshotImpl,在snapshot.h定义，源码如下:
```
class SnapshotImpl : public Snapshot {
 public:
  SequenceNumber number_;  // 保存当前快照的序列号

 private:
  friend class SnapshotList;

  // 用于插入链表时，更新前后关系
  SnapshotImpl* prev_;
  SnapshotImpl* next_;

  SnapshotList* list_;   //这个节点所属的链表，源码注释是“合理性检查”
};

```
这个是SnapShot实现类也就是dbimpl中操作的快照类，每生成一个快照时，要插入双向链表中，链表源码如下:
```
class SnapshotList {
 public:
  SnapshotList() {
    list_.prev_ = &list_;//初始dummy节点时，前后节点为自己
    list_.next_ = &list_;
  }

  bool empty() const { return list_.next_ == &list_; }//判断是否为空
  //取出最“老”的快照
  SnapshotImpl* oldest() const { assert(!empty()); return list_.next_; }
  //取出最新的快照
  SnapshotImpl* newest() const { assert(!empty()); return list_.prev_; }

  const SnapshotImpl* New(SequenceNumber seq) {
    SnapshotImpl* s = new SnapshotImpl;
    s->number_ = seq;
    s->list_ = this;
    s->next_ = &list_;
    s->prev_ = list_.prev_;
    s->prev_->next_ = s;
    s->next_->prev_ = s;
    return s;
  }//新生成一个快照，并插入链表中

  void Delete(const SnapshotImpl* s) {
    assert(s->list_ == this);
    s->prev_->next_ = s->next_;
    s->next_->prev_ = s->prev_;
    delete s;
  }//删除一个快照

 private:
  // Dummy head of doubly-linked list of snapshots
  SnapshotImpl list_;
};
```

# 上层调用实现
在dbimpl类里，定义了一个SnapshotList成员变量，用来保存以及取出快照，当用户程序调用db->GetSnapshot()时，真实调用的是:
```
const Snapshot* DBImpl::GetSnapshot() {
  MutexLock l(&mutex_);
  return snapshots_.New(versions_->LastSequence());
}
```
调用SnapshotList的new方法，用上一个序列号生成一个快照，并且插入快照链表里。当用户调用db->ReleaseSnapshot(readoptions.snapshot)时，真实调用的是:
```
void DBImpl::ReleaseSnapshot(const Snapshot* s) {
  MutexLock l(&mutex_);
  snapshots_.Delete(reinterpret_cast<const SnapshotImpl*>(s));
}
```
调用SnapshotList的delete方法，将当前使用的快照删除。

因为写入记录时，不涉及快照的问题，只有读取时，才有快照的存在。所以当系统调用db->get和db->NewIterator时，才关系快照问题。当调用get时，
1. 首先判断是否定义了readoption.snapshot，如果定义了，那么就按这个快照读取数据;
2. 如果没有定义，那么就用上一个序列号作为快照序列号来读取数据。

# 写个小程序展示快照的使用方法
实例程序如下:
```
#include<iostream>
#include<cassert>
#include<leveldb/db.h>

int main(void)
{
	leveldb::DB *db;
	leveldb::Options options;
	options.create_if_missing=true;
	leveldb::Status status=leveldb::DB::Open(options,"mydb2",&db);
	assert(status.ok());
	std::string key1="fruit";
	std::string value1="apple";
	status=db->Put(leveldb::WriteOptions(),key1,value1);
	assert(status.ok());
	leveldb::ReadOptions readoptions;
	//readoptions.snapshot=db->GetSnapshot();
	 std::string value2="orange";
	 status=db->Put(leveldb::WriteOptions(),key1,value2);
	 assert(status.ok());
	 std::string value;
	 status=db->Get(leveldb::ReadOptions(),key1,&value);
    	assert(status.ok());
	 std::cout<<value<<std::endl;
	 //db->ReleaseSnapshot(readoptions.snapshot);
	 delete db;
	 return 0;
}
	
```
这个程序很简单，一开始先往数据库插入一条键值对，接着再插入一条键值一样的记录，最后读出这个键值对应的value时，显示为最新的数据，也就是orange。

当我把两个注释去掉，并且把db->Get方法里的leveldb::ReadOptions()改成第一个注释中的readoptions时，这时输出为快照之前的数据，为apple。

在理解快照时，有参考博客[小和尚的藏经阁](http://blog.xiaoheshang.info/?p=339 "");
