title: C++STL内存池和空间配置器
date: 2015-10-26 15:49:27
tags:
- C++
- STL
- 内存池
- 空间配置器
categories:
- STL

---

最近在写论文程序，经常用到C++ STL里的模板库，但是经常记不清那些模板类的成员方法，以及当用find函数查找时，不知道怎么判断是否未找到，所以我下定决心，索性把 **STL源码剖**看了，顺便把源码学习一遍。。。

C++ STL配置器分为两层配置器，当请求的内存大于128b时，就用第一层配置器分配内存，当请求的内存小于等于128b时就调用第二层配置器。这有点类似leveldb内存池arana，当需求大于1024时，则重新分配一块内存使用，小于1024时，从内存池里获取。这样的好处就是可以减少内存分配系统调用。试想，对于128b大小的内存，如果来了一个128b请求，则第二次128b请求就需要到系统分配内存了，但是如果来了一个32b的请求，则第四次32b请求才到系统分配内存。

# 第一级配置器
先来看下源码：
```
template <int inst>
class __malloc_alloc_template {

private:
//malloc调用内存不足时调用函数
static void *oom_malloc(size_t);
//realloc调用内存不足时调用函数
static void *oom_realloc(void *, size_t);
//错误处理函数，类似C++的set_new_handler，默认值为０，如果不设置，则内存分配失败时，返回THROW_BAD_ALLOC
#ifndef __STL_STATIC_TEMPLATE_MEMBER_BUG
    static void (* __malloc_alloc_oom_handler)();
#endif

public:

static void * allocate(size_t n)
{
    void *result = malloc(n);	第一级配置器直接使用malloc分配内存
    if (0 == result) result = oom_malloc(n);//如果分配失败，则调用oom_malloc()
    return result;
}

static void deallocate(void *p, size_t /* n */)
{
    free(p);	//第一级配置器用free回收内存
}

static void * reallocate(void *p, size_t /* old_sz */, size_t new_sz)
{
    void * result = realloc(p, new_sz);	//第一级配置器用reallocate重分配内存
    if (0 == result) result = oom_realloc(p, new_sz);／／分配失败，调用oom_realloc分配
    return result;
}

// 设置分配错误处理函数，用于在oom_malloc和oom_realloc中使用
static void (* set_malloc_handler(void (*f)()))()
{
    void (* old)() = __malloc_alloc_oom_handler;
    __malloc_alloc_oom_handler = f;
    return(old);
}

};
```
第一级配置器相对简单，因为使用的正是我们平常使用的malloc，dealloc，free等，但是这个配置器提供了当内存配置错误时的处理函数oom_malloc，这个函数会调用__malloc_alloc_oom\_handler)() 这个函数，去企图释放内存，然后重新调用malloc分配内存。这个函数默认是0，所以malloc调用失败默认操作是返回\_THROW_BAD_ALLOC，来看下这个两个函数：

首先__malloc_alloc_oom_handler)() 默认值为0
```
#ifndef __STL_STATIC_TEMPLATE_MEMBER_BUG
template <int inst>
void (* __malloc_alloc_template<inst>::__malloc_alloc_oom_handler)() = 0;
#endi
```

然后是两个内存分配失败函数oom_malloc和oom_realloc
```
template <int inst>
void * __malloc_alloc_template<inst>::oom_malloc(size_t n)
{
    void (* my_malloc_handler)();//声明一个函数指针，用于赋值 __malloc_alloc_oom_handler
    void *result;//返回的内存指针

    for (;;) {	// 不断尝试释放内存，分配，再释放，再分配...
        my_malloc_handler = __malloc_alloc_oom_handler;
        if (0 == my_malloc_handler) { __THROW_BAD_ALLOC; }//为设置处理函数时，抛出错误
        (*my_malloc_handler)();		// 调用处理函数，尝试释放内存
        result = malloc(n);			// 再重新分配内存。
        if (result) return(result);//如果分配成功，返回指针
    }
}

template <int inst>
void * __malloc_alloc_template<inst>::oom_realloc(void *p, size_t n)
{
    void (* my_malloc_handler)();
    void *result;

    for (;;) {	// 不断尝试释放内存，分配，再释放，再分配...
        my_malloc_handler = __malloc_alloc_oom_handler;
        if (0 == my_malloc_handler) { __THROW_BAD_ALLOC; }////为设置处理函数时，抛出错误
        (*my_malloc_handler)();	//  调用处理函数，尝试释放内存
        result = realloc(p, n);	// 再重新分配内存。
        if (result) return(result);////如果分配成功，返回指针
    }
}
```
这两个函数，在当内存分配失败时，会不断尝试区内存释放内存，再分配内存，所以再一定程度上提高内存分配成功。当需求内存不足128b时，会调用第二层配置器，接下来分析第二层配置器。

# 第二层配置器
第二层配置器有有一个内存池，用一个union obj数组free_list来存储内存的地址，数组的每一个元素都指向一个obj链表，也就是内存链表。数组从小到大表示负责8b,16b,24b,...,120b,128b内存请求。当请求的内存为n时，会将请求上条至2的指数大小，并从数组相应位置获取内存。例如如果请求为20b，则请求会上调至24b
。
先看下union obj这个定义:
```
  union obj {
        union obj * free_list_link;//指向下一个内存的地址
        char client_data[1];    //内存的首地址
  };
```
这个定义如果看不懂，可以查看我之前写的**柔性数组**

来看下内存池模型图，来自于《STL源码剖析》:
![当从内存池请求内存时](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_019.png "")

这个图展示了当有内存请求到达时，先找到负责这个内存大小的数组元素指向的内存链表，取出第一块内存，然后把数组元素(obj指针)指向第二块内存的首地址，先介绍下几个成员:
```
  enum {__ALIGN = 8}; //内存对齐大小
  enum {__MAX_BYTES = 128};//这个数组负责最大的内存
  enum {__NFREELISTS = __MAX_BYTES/__ALIGN};//数组大小

  static size_t ROUND_UP(size_t bytes) {
        return (((bytes) + __ALIGN-1) & ~(__ALIGN - 1));
  }//将bytes上调至2的指数倍，这里就是8的倍数
 
  static obj * __VOLATILE free_list[__NFREELISTS];//内存池链表 
  static  size_t FREELIST_INDEX(size_t bytes) {
        return (((bytes) + __ALIGN-1)/__ALIGN - 1);
  }//返回负责这个内存长度的数组索引
```
```

 static void * allocate(size_t n)
  {
    obj * __VOLATILE * my_free_list;//指向数组元素的指针
    obj * __RESTRICT result;//返回的内存地址

    if (n > (size_t) __MAX_BYTES) {//如果请求内存大于128b，则调用第一级配置器
        return(malloc_alloc::allocate(n));
    }
    my_free_list = free_list + FREELIST_INDEX(n);
    // 根据请求内存大小，找到数组负责这个大小的索引位置的地址
    result = *my_free_list;//取出链表的第一块内存
    if (result == 0) {//这个链表不够内存时，调用refill重新从内存池分配
        void *r = refill(ROUND_UP(n));
        return r;
    }
    *my_free_list = result -> free_list_link;//对应索引数组的指针指向内存链表的下一块内存
    return (result);
  };
```

这是第二层配置器从内存池获取内存的调用函数，先判断请求内存是否大于128b，如果是，则调用第一级配置器，如果不是，则从第二级配置器请求一块内存。

当程序释放这块内存时，第二级配置器还负责回收这块内存，等下次有请求时，可以直接使用这块内存。示意图如下，从《STL源码剖析》摘取:
![内存池回收内存](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_020.png "");

先计算机这块内存属于哪个数组元素负责，然后将这块回收的内存放置链表的第一个位置，这块内存的下一块内存为这个链表原先的第一块内存。源码如下：
```
  static void deallocate(void *p, size_t n)
  {
    obj *q = (obj *)p;//将被回收的内存转换为obj
    obj * __VOLATILE * my_free_list;

    if (n > (size_t) __MAX_BYTES) {//大于128b，调用第一级配置器回收
        malloc_alloc::deallocate(p, n);
        return;
    }
    my_free_list = free_list + FREELIST_INDEX(n);//找到负责这块内存的数组元素
    q -> free_list_link = *my_free_list;//回收的内存的下一块内存指向原链表的第一块内存
    *my_free_list = q;//链表第一块内存指向被回收的内存
  }
```

之前分析分配内存时，当free_list没有可用的内存时，会调用refill来从内存池分配内存。例如，如果请求内存为32b，此时内存链表中没有足够的内存了，那么refill会分配20块32b的内存块，然后把第一块返回给程序，其他19块由数组相应链表管理，源码如下:
```
template <bool threads, int inst>
void* __default_alloc_template<threads, inst>::refill(size_t n)
{
    int nobjs = 20;//默认分配20块内存块
    char * chunk = chunk_alloc(n, nobjs);//从内存池获取，返回第一块
    obj * __VOLATILE * my_free_list;
    obj * result;
    obj * current_obj, * next_obj;
    int i;

    if (1 == nobjs) return(chunk);//如果只返回一块内存，直接返回
    my_free_list = free_list + FREELIST_INDEX(n);

      result = (obj *)chunk;//不止一块内存，取出第一块内存
      *my_free_list = next_obj = (obj *)(chunk + n);//数组元素链表指针指向第二块内存
      for (i = 1; ; i++) {//for循环为后续内存快建立链表关系
        current_obj = next_obj;//当前内存快
        next_obj = (obj *)((char *)next_obj + n);//下一块内存快
        if (nobjs - 1 == i) {
            current_obj -> free_list_link = 0;//最后一块的free_list_link为空
            break;
        } else {
            current_obj -> free_list_link = next_obj;//当前块的free_list_link指向下一块指针。
        }
      }
    return(result);
}
```
接下来分析真正从内存池获取内存的函数chunk_alloc。先给下内存池实际操作示意图:
![内存池实际操作示意图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_021.png "");

当free_list没有内存返回给用户时，refill函数会调用chunk_alloc从内存池获取内存，如果内存池剩余的内存(end_free-start_free)满足需求的内存(size*nobjs)，则直接从从内存池获取内存，返回给程序；当内存池的块不能满足20块时，返回一个以上的内存块；当内存池一块都不能满足时，先是回收剩余的内存，然后调用malloc从系统获取内存。如果系统内存不足，则先从数组其他链表获取内存，如果其他链表也不足够内存的话，就调用第一级内存来分配，因为第一级内存分配失败，有处理函数来解决。源码如下:
```
template <bool threads, int inst>
char*
__default_alloc_template<threads, inst>::chunk_alloc(size_t size, int& nobjs)
{
    char * result;
    size_t total_bytes = size * nobjs;//总需求内存
    size_t bytes_left = end_free - start_free;//内存池剩余的内存

    if (bytes_left >= total_bytes) {//当内存池足够内存时，从内存池里获取
        result = start_free;
        start_free += total_bytes;
        return(result);
    } else if (bytes_left >= size) {//内存池不能满足，但是又可以满足一块以上时
        nobjs = bytes_left/size;//重新设置内存块数
        total_bytes = size * nobjs;
        result = start_free;
        start_free += total_bytes;
        return(result);
    } else {//当内存池的内存小于一块内存的大小时，先将剩余内存加在数组适当的位置
        size_t bytes_to_get = 2 * total_bytes + ROUND_UP(heap_size >> 4);
        // 将剩余内存利用起来
        if (bytes_left > 0) {
            obj * __VOLATILE * my_free_list =
                        free_list + FREELIST_INDEX(bytes_left);

            ((obj *)start_free) -> free_list_link = *my_free_list;
            *my_free_list = (obj *)start_free;
        }

　　　　//调用malloc从内存分配
        start_free = (char *)malloc(bytes_to_get);
        if (0 == start_free) {//系统内存不足时
            int i;
            obj * __VOLATILE * my_free_list, *p;
            // 利用好自己拥有的内存，即从其他空闲链表获取内存.
            for (i = size; i <= __MAX_BYTES; i += __ALIGN) {
                my_free_list = free_list + FREELIST_INDEX(i);
                p = *my_free_list;
                if (0 != p) {
                    *my_free_list = p -> free_list_link;
                    start_free = (char *)p;
                    end_free = start_free + i;
		　　//递归调用chunk_alloc，因为此时获取内存了
                    //所以，递归调用时，在else if语句时，即可返回　
                    return(chunk_alloc(size, nobjs));
                }
            }
	    end_free = 0;	// 从其他链表也没获取到内存
            start_free = (char *)malloc_alloc::allocate(bytes_to_get);
            // 调用第一级配置器，因为有错误处理函数，也是最后的补救办法了
        }
        heap_size += bytes_to_get;//当从系统分配到内存时，更新到目前为止的内存总数
        end_free = start_free + bytes_to_get;
        return(chunk_alloc(size, nobjs));//递归调用，在第一个if语句即可返回。
    }
}
```
# 使用配置器
至此，STL两层配置器就分析结束了，接下来看下配置器使如何使用的。
```
template<class T, class Alloc>
class simple_alloc {

public:
    static T *allocate(size_t n)
                { return 0 == n? 0 : (T*) Alloc::allocate(n * sizeof (T)); }
    static T *allocate(void)
                { return (T*) Alloc::allocate(sizeof (T)); }
    static void deallocate(T *p, size_t n)
                { if (0 != n) Alloc::deallocate(p, n * sizeof (T)); }
    static void deallocate(T *p)
                { Alloc::deallocate(p, sizeof (T)); }
};
```
这个类封装了Alloc的分配和回收内存函数，并提供了四个用于内存操作的函数接口，一个模板是如何请求内存呢？
```
template <class T, class Alloc = alloc>  //alloc被默认为第二级配置器
class vector {
public:
  typedef T value_type;
  ...
protected:
  typedef simple_alloc<value_type, Alloc> data_allocator;
```
有代码可以看出，vector内嵌了data_allocator类型，当需要分配内存时，调用simple_alloc的成员方法即可。

参考:《STL源码剖析》和[lfsblackoverflow的博客](http://www.cnblogs.com/lfsblack/archive/2012/11/10/2764334.html)
