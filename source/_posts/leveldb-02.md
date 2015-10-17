title: leveldb源码分析之Slice
date: 2015-10-15 13:51:52
tags:
- leveldb
- slice
categories:
- leveldb

toc: ture

---
leveldb和redis这样的优秀开源框架都没有使用C++自带的字符串string，redis自己写了个sds，leveldb写了slice，本质上这三个实现原理都是一样的(当然sds是用C实现的)，都有成员属性指向字符串的指针和这个字符串的长度。方法无非就是取字符串取字符串长度，字符串拼接等等。

我把slice作为leveldb源码部分的第一个讲解，主要是slice是这个源码最基础的部分，都是别人使用它，它不使用别人。而且相对简单。

我这先上class slice源码，我一一注释：
```
class Slice {
 public:
  // Create an empty slice.
  //创建空的字符串，用法Slice slice;
  Slice() : data_(""), size_(0) { }

  // Create a slice that refers to d[0,n-1].
  //用一个字符串指针和字符串长度初始化一个Slice
  Slice(const char* d, size_t n) : data_(d), size_(n) { }

  // Create a slice that refers to the contents of "s"，
  //用C++字符串初始化Slice
  Slice(const std::string& s) : data_(s.data()), size_(s.size()) { }

  // Create a slice that refers to s[0,strlen(s)-1]
  //用一个字符串指针初始化Slice，
  Slice(const char* s) : data_(s), size_(strlen(s)) { }

  // Return a pointer to the beginning of the referenced data
  // 获取Slice字符串，不能改变值
```
这前几个函数都是Slice的构造函数，用空字符串，C风格以NULL结尾的字符串，C++ string字符串
来构造Slice。

常用的几个函数
```
  const char* data() const { return data_; }

  // Return the length (in bytes) of the referenced data
  // 获取字符串的长度
  size_t size() const { return size_; }

  // Return true iff the length of the referenced data is zero
  // 判断Slice是否为空，如果为空，返回true，如果不为空，则返回false；
  bool empty() const { return size_ == 0; }

  // Return the ith byte in the referenced data.
  // REQUIRES: n < size()
  // 重载[]操作符，用户通过slice[n]获取第n个字符
```
特定情形下使用的函数。
```
  char operator[](size_t n) const {
    assert(n < size());
    return data_[n];
  }

  // Change this slice to refer to an empty array
  //将这个Slice清空
  void clear() { data_ = ""; size_ = 0; }

  // Drop the first "n" bytes from this slice.
  //去除Slice前缀n个字符，例如为了取出Status信息，需要去除前5个前缀字符
  void remove_prefix(size_t n) {
    assert(n <= size());
    data_ += n;//指针向前移动n个字符
    size_ -= n;//长度减n
  }

  // Return a string that contains the copy of the referenced data.
  //返回Slice的string形式的副本
  std::string ToString() const { return std::string(data_, size_); }

  // Three-way comparison.  Returns value:
  //   <  0 iff "*this" <  "b",
  //   == 0 iff "*this" == "b",
  //   >  0 iff "*this" >  "b"
  int compare(const Slice& b) const;

  // Return true iff "x" is a prefix of "*this"
  // 判断这个Slice是否以字符串x为前缀
  bool starts_with(const Slice& x) const {
    return ((size_ >= x.size_) &&
            (memcmp(data_, x.data_, x.size_) == 0));
  }

 private:
  const char* data_;
  size_t size_;

  // Intentionally copyable
};


// 重载==操作符，用于判断Slice==Slice
inline bool operator==(const Slice& x, const Slice& y) {
  return ((x.size() == y.size()) &&
          (memcmp(x.data(), y.data(), x.size()) == 0));
}

// 重载不等于操作符
inline bool operator!=(const Slice& x, const Slice& y) {
  return !(x == y);
}

//字符串比较函数
inline int Slice::compare(const Slice& b) const {
  const size_t min_len = (size_ < b.size_) ? size_ : b.size_;
  int r = memcmp(data_, b.data_, min_len);
  if (r == 0) {//字符串相等的情况下，可能长度不一样，所以也要进行判断。
    if (size_ < b.size_) r = -1;
    else if (size_ > b.size_) r = +1;
  }
  return r;
}
```
leveldb的字符串Slice还是算比较简单的，相比与redis的sds,sds还有字符串的拼接啦，长整形和字符串互转等等。
简单使用：
```
//声明定义一个空字符串
Slice slice；
//有一个字符串指针初始化Slice
const char* p="orange"
Slice slice(p);
//获取Slice的字符串
slice.data();
//获取Slice字符串的长度
slice.size()
```
Slice分析到此就结束了，下一篇，主要介绍下状态类Status.






