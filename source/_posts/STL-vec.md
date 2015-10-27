title: STL源码分析之vector
date: 2015-10-27 19:00:14
tags:
- C++
- STL
- vector
categories:
- STL

---

C++标准模板库在日程编程应用非常的广泛，之前看到一篇大牛文章说，用C++开发，尽量用容器类+迭代器来代替数组+指针，因为数组+指针容易越界，或者内存泄露，相反，容器类和+迭代器都有国外大神将底层封装好，使用安全简单。而且标准模板库再一定程度上可以提高我们编程效率，假如要对一个结构体数组排序，写一个比较函数或者仿函数，调用sort函数即可。换做是c语言，还需自己写排序函数。。。

vector是有序容器里使用最广泛的容器。今天想分析下vector这个容器的实现，看这个文章之前，需要好好理解typetraits和iterator_traits，这两个是就是著名的特性萃取器，一个是萃取类型，一个是萃取迭代器类型。由于这两个东西很繁琐，就不写了，在代码中有用到地方，会有注释。

对了，再这篇文章之前，还需要把我之前[内存池和配置器](http://luodw.github.io/2015/10/26/Calloc/#more "")文章看看，因为底层是用这个分配内存。

# 构造函数
先介绍vector这个模板类的成员变量:
```
  //这不能算是成员变量，只能算内嵌类型，用于分配内存
  typedef simple_alloc<value_type, Alloc> data_allocator;
  //表示目前使用空间的头
  iterator start;
  //表示目前使用空间的尾
  iterator finish;
  //表示目前可用空间的尾
  iterator end_of_storage;
```
finish表示下一个存储数据的位置，也就是说vector数组是存储在[start,end)里面的，而end_of_storage是可用的空间的尾，也就是说在finish和end_of_storage之间还可以存储数据，如果有容量的话。

好接下来是构造函数，首先是默认构造函数:
```
//默认构造函数，迭代器都初始化为０，此时没有内存空间
vector() : start(0), finish(0), end_of_storage(0) {}
//用n个数类初始化vector
  vector(size_type n, const T& value) { fill_initialize(n, value); }
  vector(int n, const T& value) { fill_initialize(n, value); }
  vector(long n, const T& value) { fill_initialize(n, value); }
  explicit vector(size_type n) { fill_initialize(n, T()); }
```
这四个函数都调用了fill_initialize(size\_type n, const T& value) 这个函数，这个函数先调用allocate_and_fill这个函数分配内醋，并且填充数据。先看下fill_initialize函数:
```
 void fill_initialize(size_type n, const T& value) {
    start = allocate_and_fill(n, value);//分配内存，并且填充数据
    finish = start + n;//finish向后移动n个类型单位
    end_of_storage = finish;//可用空间和已使用空间相等
  }
```
接来下看下allocate_and_fill这个函数:
```
  iterator allocate_and_fill(size_type n, const T& x) {
    iterator result = data_allocator::allocate(n);//先调用配置器，分配内存
    __STL_TRY {
      uninitialized_fill_n(result, n, x);//这个函数用来向内存填充数据
      return result;//返回内存首地址
    }
    __STL_UNWIND(data_allocator::deallocate(result, n))//出现错误删除分配的内存;
  }
```
这个函数要说明几点:
1. n是类型大小内存单元个数，作为data_allocator::allocate(n)这个函数的参数，并不是就分配n个字节，因为在allocate函数内部是如下调用的:
```
 static T *allocate(size_t n)  
        { return 0 == n? 0 : (T*) Alloc::allocate(n * sizeof (T)); }  
```
所以分配到的内存是n个sizeof(T)大小的内存。
2. 这个函数uninitialized_fill\_n是内处处理函数，在 stl_uninitialized.h这个文件中，这个文件还包含了好几个类似函数。
3. 如果一块内存单元赋值错误，那么会删除所有内存，就是类似"commit and rollback"回滚的功能。

接下看下 uninitialized_fill_n这个函数:
```
template <class ForwardIterator, class Size, class T>
inline ForwardIterator uninitialized_fill_n(ForwardIterator first, Size n,
                                            const T& x) {
  return __uninitialized_fill_n(first, n, x, value_type(first));
}
```
这个函数根据这个vector的数据类型，调用不同的函数:
```
template <class ForwardIterator, class Size, class T, class T1>
inline ForwardIterator __uninitialized_fill_n(ForwardIterator first, Size n,
                                              const T& x, T1*) {
  typedef typename __type_traits<T1>::is_POD_type is_POD;
  return __uninitialized_fill_n_aux(first, n, x, is_POD());
                                    
}
```
先判断这个数据类型是否是POD，POD是plain old data的简称，表示c语言的基础数据类型，int ,long,double等等，还有c语言的struct接口。如果是POD类型，直接用fill_n函数填充内存即可；如果不是POD类型，就需要调用构造函数来初始化内存，代码如下:
```
template <class ForwardIterator, class Size, class T>
inline ForwardIterator
__uninitialized_fill_n_aux(ForwardIterator first, Size n,
                           const T& x, __true_type) {
  return fill_n(first, n, x);//类似int类型，直接用fill_n填充即可
}

template <class ForwardIterator, class Size, class T>
ForwardIterator
__uninitialized_fill_n_aux(ForwardIterator first, Size n,
                           const T& x, __false_type) {
  ForwardIterator cur = first;
  __STL_TRY {
    for ( ; n > 0; --n, ++cur)
      construct(&*cur, x);//调用构造函数，这里用的是placement new来构造
    return cur;
  }
  __STL_UNWIND(destroy(first, cur));
}
```
这里的构造函数调用是placement new，代码如下:
```
template <class T1, class T2>
inline void construct(T1* p, const T2& value) {
  new (p) T1(value);  //将value值构造在内存p的位置
}
```
到此为止，构造函数已构造完毕，接下来看下复制构造函数
```
  vector(const vector<T, Alloc>& x) {
    start = allocate_and_copy(x.end() - x.begin(), x.begin(), x.end());
    finish = start + (x.end() - x.begin());
    end_of_storage = finish;
  }
```
先调用allocate_and_copy函数分配内存，以及复制数据,该函数如下；
```
  template <class ForwardIterator>
  iterator allocate_and_copy(size_type n,
                             ForwardIterator first, ForwardIterator last) {
    iterator result = data_allocator::allocate(n);//分配内存
    __STL_TRY {
      uninitialized_copy(first, last, result);//复制函数
      return result;
    }
   }
    __STL_UNWIND(data_allocator::deallocate(result, n));
  }
```
接下来，看下uninitialized_copy这个函数；
```
template <class InputIterator, class ForwardIterator>
inline ForwardIterator
  uninitialized_copy(InputIterator first, InputIterator last,
                     ForwardIterator result) {
  return __uninitialized_copy(first, last, result, value_type(result));
}
```
根据值的类型，调用不同的函数。也是区分是否为POD，调用不同的复制函数，这里不再讲述。

# 析构函数
这里构造函数暂时讲这么多，接来下，看下析构函数，析构函数很简单，先析构[start,finidh)，然后再把内存还给系统或内存池，来看下代码:
```
  ~vector() { 
    destroy(start, finish);  //析构start到finish之间的数据
    deallocate();  // 释放内存
  }
```
destroy函数根据数据类型，如果是POD，则什么都不做，如果不是POD，则需要调用析构函数一个一个的析构。deallocate函数如下:
```
  void deallocate() {
    if (start) data_allocator::deallocate(start, end_of_storage - start);
  }
```
这个函数回收[start,end_of_storage)之间的内存，如果是大于128b，则还给系统，如果小于128b，则还给内存池，后面可以继续使用。

# 一些常用函数
## push_back函数
当创建一个空的vector时，此时空间为0，所以需要分配１个内存；当空间不够，且此时空间大小不为空时，分配原有空间的一倍，用于后续使用。来看下代码:
```
  void push_back(const T& x) {
    if (finish != end_of_storage) {
      construct(finish, x);    //当还有空间时，直接在finish赋值，然后finish向后移动一个单位
      ++finish;
    }
    else
      insert_aux(end(), x);//内存不够时，调用分配函数，并赋值
  }
```
来看下insert_aux()函数:
```
template <class T, class Alloc>
void vector<T, Alloc>::insert_aux(iterator position, const T& x) {
  if (finish != end_of_storage) {
    construct(finish, *(finish - 1));
    ++finish;
    T x_copy = x;
    copy_backward(position, finish - 2, finish - 1);//把position到finish-2都向后移动一个单位，将position空间留出来
    *position = x_copy;//给这个空间赋值
  }
  else {
    const size_type old_size = size();
    const size_type len = old_size != 0 ? 2 * old_size : 1;//设置新长度
    iterator new_start = data_allocator::allocate(len);//分配新空间
    iterator new_finish = new_start;//finish和start一样
    __STL_TRY {
      //将[start,position)赋值到new_start
      new_finish = uninitialized_copy(start, position, new_start);
      //将x放置在new_finish处
      construct(new_finish, x);
      ++new_finish;//new_finish向后移动一个单位
      //将[position,finish)赋值到new_finish
      new_finish = uninitialized_copy(position, finish, new_finish);
    }

#       ifdef  __STL_USE_EXCEPTIONS 
    catch(...) {
      destroy(new_start, new_finish); 
      data_allocator::deallocate(new_start, len);
      throw;//错误删除分配空间
    }
#       endif /* __STL_USE_EXCEPTIONS */
    destroy(begin(), end());//析构原空间数据
    deallocate();//释放原内存
    start = new_start;//更新start值
    finish = new_finish;//更新finish值
    end_of_storage = new_start + len;
  }
}
```
>根据这个函数，可以得到在使用vector过程中一个非常重要的注意点。因为没增加一个元素时，都有可能重新分配内存，那么原先的迭代器就将失效了，因为指向的内存已经被析构了。所以vector有添加数据时，一定要重新定义迭代器。

## 一些小函数
```
  iterator begin() { return start; }//初始迭代器
  const_iterator begin() const { return start; }//const迭代器
  iterator end() { return finish; }//末端迭代器
  const_iterator end() const { return finish; }
  reverse_iterator rbegin() { return reverse_iterator(end()); }//逆向迭代器
  const_reverse_iterator rbegin() const { 
    return const_reverse_iterator(end()); 
  }
  reverse_iterator rend() { return reverse_iterator(begin()); }//逆向迭代器
  const_reverse_iterator rend() const { 
    return const_reverse_iterator(begin()); 
  }
  size_type size() const { return size_type(end() - begin()); }//vector元素个数
  size_type max_size() const { return size_type(-1) / sizeof(T); }//vector最多可以容纳元素个数
  //vector容量
  size_type capacity() const { return size_type(end_of_storage - begin()); }
  bool empty() const { return begin() == end(); }
  reference operator[](size_type n) { return *(begin() + n); }
  const_reference operator[](size_type n) const { return *(begin() + n); }
```
这些小函数，最重要要区分size()和capacity()函数，前者是vector已有的元素数量，后者是这个vector总共可以存储的元素数量。

# erase函数
这个函数有一个注意点，所以这里讲解下:
```
  iterator erase(iterator position) {
    if (position + 1 != end())
      copy(position + 1, finish, position);//将[position+1,finish)向前移动一个单位
    --finish;
    destroy(finish);//析构最后一个元素
    return position;//返回擦除位置的迭代器
  }
  iterator erase(iterator first, iterator last) {//擦除一段元素
    iterator i = copy(last, finish, first);//将[last,finish)向前移动last-first个单位
    destroy(i, finish);//析构i到finish之间的元素，但是还可以用
    finish = finish - (last - first);//更新finish
    return first;
  }
```
这个函数需要注意的是，当删除一段元素时，size()大小是会变化的，但是capacity()是不变的。

其他函数就不一一介绍了。接下来总结下:
1. 在看vector函数之前，一定要弄懂内存池，配置器和特性萃取，否则看不懂vector源码。
2. 当向vector一个元素时，此时的迭代器是不安全的，需要重新定义。
3. 当调用erase函数时，size()函数会变化，capacity不会花生变化。
