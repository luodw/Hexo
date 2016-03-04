title: leveldb回顾之任务调度器
date: 2016-02-27 21:08:27
tags:
- leveldb
categories:
- leveldb
toc: true

---

今天偶然在浏览技术博客的时候,突然发现了leveldb原来还有一个很有意思的模块,即任务调度模块.leveldb任务调度模块,主要思想就是消费者与生产者.即任务调度器往任务队列添加任务,当后台没有任务调度时,调度器会从任务队列中取出第一个任务执行,即先进先出队列.

我们来源码看下,任务调度函数主要是:
```
void PosixEnv::Schedule(void (*function)(void*), void* arg) {
  PthreadCall("lock", pthread_mutex_lock(&mu_));
  // 如果没有后台线程,则直接从任务队列中取出最后一个任务执行
  if (!started_bgthread_) {
    started_bgthread_ = true;
    PthreadCall(
        "create thread",
        pthread_create(&bgthread_, NULL,  &PosixEnv::BGThreadWrapper, this));
  }

  // 如果任务队列为空,则唤醒BGThread后台线程,因为即将往队列添加任务
  if (queue_.empty()) {
    PthreadCall("signal", pthread_cond_signal(&bgsignal_));
  }

  // 任务添加进队列
  queue_.push_back(BGItem());
  queue_.back().function = function;
  queue_.back().arg = arg;

  PthreadCall("unlock", pthread_mutex_unlock(&mu_));
}
```
线程函数&PosixEnv::BGThreadWrapper其实就是BGThread函数的封装,在BGThread就函数中,先判断队列是否为空,如果是,则wait,等待被调度器唤醒.如果不为空,则取出第一个任务,执行:
```
void PosixEnv::BGThread() {
  while (true) {
    // Wait until there is an item that is ready to run
    PthreadCall("lock", pthread_mutex_lock(&mu_));
    while (queue_.empty()) {
      PthreadCall("wait", pthread_cond_wait(&bgsignal_, &mu_));
    }//等待被唤醒

    void (*function)(void*) = queue_.front().function;
    void* arg = queue_.front().arg;
    queue_.pop_front();//弹出第一个任务

    PthreadCall("unlock", pthread_mutex_unlock(&mu_));
    (*function)(arg);//执行任务函数
  }
}
```

这个任务队列挺简单的,我写这个的目的了,是因为之前的生产者消费者模型队列主要是用于存储数据,而这次是用于存储任务函数指针,这是一个亮点,给了我对任务调度最初步的理解.






























