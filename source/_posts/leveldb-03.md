title: leveldb源码分析之Status
date: 2015-10-15 14:55:43
tags:
- leveldb
- Status
categories:
- leveldb
toc: true

---

Status类是leveldb用来判断某个函数执行返回时的状态，状态主要是用迭代类型enum类表示
```
enum Code {
  kOk = 0,
  kNotFound = 1,
  kCorruption = 2,
  kNotSupported = 3,
  kInvalidArgument = 4,
  kIOError = 5
}
```

可能很多人对enum这种类型并不是很熟，因为平常使用的并不多。接下来先简单介绍下enum。

enum类型本质是上一种int类型，4个字节，上述代码是不占内存的，因为上述只是enum Code的声明，表示Code类型的变量只能是上述6个值中的某一个，Code code这样才定义了一个Code类型，而且code只能使用声明中列出的字符串来初始化，不能用其他整形变量来初始化。像sizeof(code)=4;

像如下的调用
```
Code code=kOk;
cout<<code<<endl;
```
将会输出0.

Status本质就一个成员变量const char* state_;为了节省内存，state_分三部分使用:
* state_[0..3]:消息的长度，不包括前5个字节
* state_[4]:消息的类型
* state_[5..]:具体的消息内容

介绍主要几个函数：
```
static Status OK() { return Status(); }

  // Return error status of an appropriate type.
  static Status NotFound(const Slice& msg, const Slice& msg2 = Slice()) {
    return Status(kNotFound, msg, msg2);
  }
  static Status Corruption(const Slice& msg, const Slice& msg2 = Slice()) {
    return Status(kCorruption, msg, msg2);
  }
  static Status NotSupported(const Slice& msg, const Slice& msg2 = Slice()) {
    return Status(kNotSupported, msg, msg2);
  }
  static Status InvalidArgument(const Slice& msg, const Slice& msg2 = Slice()) {
    return Status(kInvalidArgument, msg, msg2);
  }
  static Status IOError(const Slice& msg, const Slice& msg2 = Slice()) {
    return Status(kIOError, msg, msg2);
  }
```
这几个静态函数用于直接返回一个特定类型的Status对象，这有个调用的例子
```
Status s;
//以下调用会用到赋值操作符
s = Status::Corruption("corrupted key for ", user_key);//version_set.cc 413页
```
这几个函数直接调用的是以下函数
```
Status(Code code, const Slice& msg, const Slice& msg2);
```
实现如下：
```
Status::Status(Code code, const Slice& msg, const Slice& msg2) {
  assert(code != kOk);
  const uint32_t len1 = msg.size();
  const uint32_t len2 = msg2.size();
  const uint32_t size = len1 + (len2 ? (2 + len2) : 0);//判断第二个字符串长度是否为0，
如果不为0，则信息总长度为len1+2+len2，这里的2是用于存储':'和' '。
  char* result = new char[size + 5];//state_总长度还包括前5个
  memcpy(result, &size, sizeof(size));//将信息长度存入result前四个字节
  result[4] = static_cast<char>(code);//第5个字节存状态。
  memcpy(result + 5, msg.data(), len1);//第6个字节开始存信息内容
  if (len2) {//如果msg2不为空，则信息内容还用加上': '+msg2。
    result[5 + len1] = ':';
    result[6 + len1] = ' ';
    memcpy(result + 7 + len1, msg2.data(), len2);
  }
  state_ = result;
}
```
接下来，介绍下复制构造函数和赋值操作符，之前也提到有用到这赋值操作符。
```
inline Status::Status(const Status& s) {
  state_ = (s.state_ == NULL) ? NULL : CopyState(s.state_);
}
inline void Status::operator=(const Status& s) {
  if (state_ != s.state_) {
    delete[] state_;
    state_ = (s.state_ == NULL) ? NULL : CopyState(s.state_);
  }
}
```

本质上都是调用CopyState来复制s.state\_的内容。这并不不是简单的bitwise copy，因为CopyState有重新开辟一块内存存储s.state\_的内容,然后把指针赋给调用函数的s.state_指针。

接下来几个都是用于判断状态的成员方法。直接通过code()函数返回这个Status的状态。
```
  // Returns true iff the status indicates success.
  bool ok() const { return (state_ == NULL); }

  // Returns true iff the status indicates a NotFound error.
  bool IsNotFound() const { return code() == kNotFound; }

  // Returns true iff the status indicates a Corruption error.
  bool IsCorruption() const { return code() == kCorruption; }

  // Returns true iff the status indicates an IOError.
  bool IsIOError() const { return code() == kIOError; }
```
code函数的定义如下：
```
 Code code() const {
    return (state_ == NULL) ? kOk : static_cast<Code>(state_[4]);
  }
```
这个函数先判断state_是否为空，如果为空，则返回kOk，否则取出state_第四个字节，转换为Code类型返回。

最后简单摘录几个调用的例子：
1. 
```
 Status s;
 s = descriptor_log_->AddRecord(record);
      if (s.ok()) {
```
2. 
```
 s = Status::Corruption("corrupted key for ", user_key);
```

总结下：Status这个类调用场景，主要是在某个函数fun里面定义一个Status，可以通过静态函数返回值获得或者调用另一个返回值获得，最后fun返回时，检查这个函数的返回状态。
