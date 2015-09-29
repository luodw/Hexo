title: C语言一些低调的函数
date: 2015-09-28 22:18:45
tags:
- C/C++
- C函数
- strchr
- strtok
- getopt
categories:
- C/C++
  
---

C语言一些函数平时很少见,但是有时候却非常有用.也别是字符串处理函数和主函数处理函数.

## strchr和strrchr
 
首先出场的是strchr和strrchr函数,原型如下:

```
#include<string.h>
c har *strchr(char const *str,int ch);
char *strrchr(char const *str,int ch);
```

strchr函数主要功能就是查找ch在字符串str中首次出现的位置,然后函数返回指向这个位置的指针.strrchr函数功能和strchr函数基本一致,只是它查找的是ch在字符串str最后出现的位置,并返回指向这个位置的指针.

有以下例子:
```
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
	char const *p="hello,world,wou!";
	char *ans;
	ans=strchr(p,'w');
	printf("%s\n",ans);
	ans=strrchr(p,'w');
	printf("%s\n",ans);
	return 0;
}
```

输出为:

```
world,wou!
wou!
```

## strspn和strcspn
函数原型如下:
```
#include<string.h>
size_t strspn(char const *str,char const *group);
size_t strcspn(char const *str,char const *group);

```

strspn函数功能是返回str起始部分开始,与group中任意字符不匹配的第一个的位置.strcspn函数功能与strspn相反,它返回的是str起始部分开始,与group中任意字符匹配的第一个位置.

举个例子:
```
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
	int len1,len2,len3;
	char buffer[]="25,142,330,Smith,J,239-4123";
	len1=strspn(buffer,"0123456789");
	len2=strspn(buffer,",0123456789");
	printf("%d\t%d\n",len1,len2);
	char buffer1[]="fcb74";
	len3=strcspn(buffer1,"0123456789");
	printf("%d\n",len3);
	return 0;
}
```
输出为:
```
2	11
3

```

## strtok
函数原型为:
```
#include<string.h>
char *strtok(char *str,char const *sep);
```
sep是字符串,定义了用作分隔符的字符集合.函数找到str的下一个标记,并将其用NULL结尾,然后返回一个指向这个标记的指针.一般的用法是第一次调用第一个参数为指向字符串的指针,之后都用NULL作为第一个参数,这样可以输出分割出的所有子字符串.

举个例子:
```
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void)
{
	char s[] = "ab-cd : ef;gh :i-jkl;mnop;qrs-tu: vwx-y;z";
	char *delim = "-: ";
	char *p;
   	printf("%s ", strtok(s, delim));
    	while((p = strtok(NULL, delim)))
	printf("%s ", p);
	printf("\n");								   
      return 0;								
}
```
输出为:
```
ab cd ef;gh i jkl;mnop;qrs tu vwx y;z
```

## 参数处理函数getopt
在看UNIX进程间通信机制时,经常看到的函数就是getopt,然后平时我们又很少接触到.
函数原型为:
```
#include<unistd.h>
int getopt(int argc,char * const argv[ ],const char * optstring);
extern char *optarg;
extern int optind, opterr, optopt;
```
这个函数设置了几个全局变量,optarg——指向当前选项参数（如果有）的指针.optind——再次调用 getopt() 时的下一个 argv 指针的索引.optopt——最后一个未知选项

optstring的指定的内容的意义(例如getopt(argc,argv,"ab:c:de::");
1. 单个字符,表示选项,例如上述函数参数,可以在运行程序时,添加选项-a
2. 单个字符后街一个冒号:表示该选项后必须跟一个参数,参数紧跟在选项后或者空格隔开.该参数的指针赋给optarg,例如可以添加-b 123
3. 单个字符后跟两个冒号::,表示后面可以跟一个参数或者不跟.

举个例子:
```
#include <stdio.h>
#include <unistd.h>
 
int main(int argc,char *argv[])
{
  int ch;
  opterr=0;
  
  while((ch=getopt(argc,argv,"a:b::cde"))!=-1)
  {
    printf("optind:%d\n",optind);
    printf("optarg:%s\n",optarg);
    printf("ch:%c\n",ch);
    switch(ch)
    {
      case 'a':
        printf("option a:'%s'\n",optarg);
        break;
      case 'b':
        printf("option b:'%s'\n",optarg);
        break;
      case 'c':
        printf("option c\n");
        break;
      case 'd':
        printf("option d\n");
        break;
      case 'e':
        printf("option e\n");
        break;
      default:
        printf("other option:%c\n",ch);
    }
    printf("optopt+%c\n",optopt);
  }

}  
```
我们可以这样来调用上述程序:
```
./a.out -a1234 -b432 -c -d
```

输出为:
```
optind:2
optarg:1234
ch:a
option a:'1234'
optopt+
optind:3
optarg:432
ch:b
option b:'432'
optopt+
optind:4
optarg:(null)
ch:c
option c
optopt+
optind:5
optarg:(null)
ch:d
option d
optopt+
```
要理解上述输出,先分析参数
1. argc=5;
2. argv[0]=a.out
2. argv[1]=-a1234
3. argv[2]=-b432
4. argv[3]=-c 
5. argv[4]=-d

getopt函数中的argc和argv即为main函数参数argc和argv.全局变量optind默认值为1,所以getopt第一次读取的参数为argv[1],然后optind+1.所以第一次输出optind=2,argv[1]的选项为a,参数字符串为1234.

如果getopt找不到符合的参数则会印出错误的信息,并将全局变量optopt设为"?"字符.
上述输出均为字符"+",则说明找到了符合的参数,没有出错.后面的分析和上面一样.

如果不希望getopt打印出错误信息,只有将全局变量opterr设为即可.

**参考**
> C与指针
> 
> 雪精灵的专栏博客 <http://blog.csdn.net/baixue6269/article/details/7550184>
 
















