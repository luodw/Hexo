title: linux一些软件配置
date: 2015-09-25 22:49:07
tags:
- Configure
categories:
- Configure
toc: true
---

平时在用linux安装软件时的一些配置,记录下来

#### 安装eclipse在桌面创建图标

```
首先：gedit /usr/share/applications/eclipse.desktop
内容输入：
[Desktop Entry]
Encoding=UTF-8
Name=Eclipse
Comment=Eclipse IDE
Exec=/usr/local/android/eclipse/eclipse
Icon=/usr/local/android/eclipse/icon.xpm
Terminal=false
StartupNotify=true
Type=Application
Categories=Application;Development;
eclipse配置CDT，到官网下载CDT，http://www.eclipse.org/cdt/，然后安装
```

#### 安装MySQL

```
执行sudo apt-get install mysql-server mysql-client进行安装 MySQL。
mysql  用户名:root   密码：root
```

#### VIM换行缩进

```
在主目录下新建．vimrc文件，在该文件中输入一下内容
set tabstop=4 
set softtabstop=4 
set shiftwidth=4 
set noexpandtab 
set nu  
set autoindent 
set cindent
解释：Tabstop:表示一个 tab 显示出来是多少个空格的长度?默认 8。
Softtabstop:表示在编辑模式的时候按退格键的时候退回缩进的长度?当使用 expandtab 时特别有用。
Shiftwidth:表示每一级缩进的长度?一般设置成跟 softtabstop 一样。 当设置成 expandtab 时?缩进用空格来表示?noexpandtab 则是用制表符表示一个缩进。
Nu:表示显示行号。
Autoindent:表示自动缩进。
Cindent:是特别针对C语言自动缩进
```

#### Linux配置Hiredis

```
博客地址：http://www.ithao123.cn/content-998027.html
```

#### 静态链接库和动态链接库

```
静态链接库只需放在可执行程序同一个文件夹下即可，程序编译的时候,
    gcc test.c libtest.a -o test即可
动态链接库必须放在系统可查询的目录下，调用时加-l，顺序如下：
　　1.首先查询/etc/ld.so.conf.d目录下所有*.conf文件中的路径;
    2./usr/lib
    3./lib
    如果是通过make install添加的动态链接库，则可以什么都不要做；
    但是，如果是自己复制黏贴进相应的目录的时候，则需要运行命令ldconfig，
将新添加的动态链接库的信息添加进ld.so.cache缓冲，不然会报错，找不到相
应的库函数
```



> Written with [StackEdit](https://stackedit.io/).
