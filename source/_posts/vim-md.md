title: vim配置markdown语法高亮
date: 2015-09-26 21:46:28
tags:
- Configure
categories: 
- Configure 
toc: true
 
---

linux下写markdown,目前还没看到很优秀的编辑器,sublime是一款非常不错都编辑器,可是对中文支持不是很好,所以只能投向与**vim**的怀抱.

<!--more-->

vim有一个插件markdown对markdown提供语法高亮支持,非常实用,安装如下:

* github下载: <https://github.com/plasticboy/vim-markdown> 
* 解压之后有两个文件夹,syntax和ftdetect,里面都含有文件markdown.vim,将两个文件拷贝到$VIM下对用的syntax和ftdetect,没有的话,则自己新建.可以执行以下命令:
```
cp ./syntax/markdown.vim ~/.vim/syntax/
cp ./ftdetect/markdown.vim ~/.vim/ftdetect/ 
```

一切就是这么简单，复制到对应目录，然后重启你的vim就ok了。

#### 插件内容
 
尽管名字相同，两个文件夹中的文件是不同的。
   1.  syntax中的 mkd.vim 是关键的语法解析文件，里面是关于语法高亮的详细定义。
   2. ftdetect中的 mkd.vim 定义的是自动解析哪些文件。

   下面是github最新版本中的定义方式，支持的后缀名包括花括号中的内容，如果有新的定义，可以自己加.

   au BufRead,BufNewFile *.{md,mdown,mkd,mkdn,markdown,mdwn}   set filetype=mkd 


