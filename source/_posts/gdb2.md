title: 利用core文件分析程序段错误
date: 2015-10-08 14:47:57
tags:
- C/C++
- linux
- gdb
- core
- Segmentation fault
categories:
- C/C++
- Linux
- Gdb

---

经过昨天使用反汇编理解c函数栈的调用过程之后，今天阅读相关文章，发现gdb分析core文件挺有意思的，所以就研究了下．

我们经常在编程过程遇到过段错误，段错误出现的原因好一些，我知道就是访问栈溢出外的内存，将一块内存地址(并非函数入口)强制转化为函数指针，访问int *p=NULL指针等等，有时候我们并不知道出现错误的位置在哪，这时就可以用gdb分析．

这是用到的例子程序:
```
#include <stdio.h>
void test_core()
{
        int a[100000000];
        int b=1;
        printf("%d\n",b);
}
int main()
{
        test_core();
        return 0;
}
```
要用core文件，首先要产生core文件．系统默认是不产生core文件的．通过命令
```
ulimit -c　
```
可以设置．默认情况下该命令的值为0，表示不产生core文件．通过命令
```
ulimit -cn(n为core文件最大值，单位kb)
```
我设置为1024kb，如下图所示：
![core文件产生过程](http://7xjnip.com1.z0.glb.clouddn.com/选区_009.png "")

接下来，我们通过gdb命令分析core文件．
```
gdb ./core_test core
```
程序输出如下：
![gdb分析core文件界面](http://7xjnip.com1.z0.glb.clouddn.com/选区_010.png "")

从图片可以看出，该程序出现段错误是由test_core()函数中，第5行导致的．主要因为之前为a申请的内存太大，超出了系统允许每个进程的栈大小．默认值是8192kb，可以通过ulimit -s查看．所以当访问b时，访问的是一个超出栈的地址空间，所以出现段错误．

我们可以查看此时的栈帧信息，如下:
![出现错误的栈帧信息](http://7xjnip.com1.z0.glb.clouddn.com/选区_011.png "")
从图中可以看出，rip寄存器指向的是指令0x400538，也就是出现段错误的位置．可以查看$rip指令处的汇编代码，如下:
![段错误的指令位置](http://7xjnip.com1.z0.glb.clouddn.com/选区_013.png "")
可以查看出错的内存位置．当我们访问那个内存位置时出现可错误，因为超出栈空间．

参考博客：<http://baidutech.blog.51cto.com/4114344/904419/>












