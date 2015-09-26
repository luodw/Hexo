title: c语言字符数组一些启示
date: 2015-09-23 21:08:59
tags:
- C/C++
categories:
- C/C++
toc: true
---

　　最近博主在学习《linux系统编程》，所以想记下来学习的一些心得，与大家分享，也备以后回顾只用。
　　第一天，就从我在今天学习过程遇到的问题写起，博主今天在学习标准IO库，遇到一个问题，
关于字符指针的问题，代码如下：

<!--more-->


```
#include <stdio.h>
#include <stdlib.h> 
int main()
{
  FILE *stream;
  char *s;
  int c;
  int n=6;
  stream=fopen("./test.txt","r");
while(--n>0 && (c=fgetc(stream))!=EOF)
{
  *s++=c;
}
  *s='\0';
  printf("s=%s\n",s);
  exit(0);
}
```


  　　本程序很简单，就是以标准流的形式打开一个文件，然后从文件读取n-1个字符，但是运行这个程序的时候，会出现段错误，百度之后，得知，是因为使用了未申请的内存或者申请的内存有错误，那么问题出现在哪了？
  　　通过查资料得知问题出现在char *s 和*s++=c。因为在程序中，字符指针没有初始化，即没有给该指针赋值（s不知道指向何处），那么如果给该指针赋值，那么值不知存哪去，而s++也没有意义。所以应该先给s赋值一个地址字符数组的地址，然后在往这个地址赋值，加1赋值等等。所以改进代码如下


```
  1 #include<stdio.h>
  2 #include<stdlib.h>
  3 
  4 int main()
  5 {
  6     FILE *stream;
  7     char *s;
  8     char str[1024];
  9     s=str;
 10     int c;
 11     int n=6;
 12     stream=fopen("./test.txt","r");
 13     while(--n>0  &&  (c=fgetc(stream))!=EOF)
 14     {   
 15         *s++=c;
 16     }
 17     *s='\0';
 18     printf("s=%s\n",str);
 19     exit(0);
 20 }
```


　　运行结果如下图所示：
![运行结果](http://img.blog.csdn.net/20150219205507506?watermark/2/text/aHR0cDovL2Jsb2cuY3Nkbi5uZXQvcXE5NzI5NDk3Mg==/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70/gravity/SouthEast "")
　　由于较少使用c语言，所以一些基本的知识点都忘了，所以我也感受到了，学习语言一定要多写，看着都懂，但是当自己写的时候，就会碰到各种细节问题。平时看起来很简单的问题，当自己亲身躬为的时候，有时候并不是那么简单。
　　可能我写很基础或不是完全正确，希望大神可以指点指点。
