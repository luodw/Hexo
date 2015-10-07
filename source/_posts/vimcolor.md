title: vim配色Solarized
date: 2015-10-06 15:37:58
tags:
- Configure
- Vim
- Solarized
categories:
- Configure
- Vim

---

vim配色方案由好多中，如果厌烦了系统自带的颜色，可以尝试修改vim配色，给自己个新鲜感．其中solarized配色是我最喜欢一种．
![Solarized配色](http://7xjnip.com1.z0.glb.clouddn.com/选区_004.png "")
网上很多教程是针对mac改造的，所以照着教程做下来，vim是不能显示浅蓝色背景，所以还需要Gnome-Terminal设置背景色．

### 先改终端的配色为Solarized
要先设置Terminal配色，否则ls命令下都是灰蒙蒙的．
```
git clone git://github.com/seebi/dircolors-solarized.git
```
dircolor-solarized 有几个配色，你可以去项目那看看说明，我自己用的是 dark256：
```
cp ~/dircolors-solarized/dircolors.256dark ~/.dircolors
eval 'dircolors .dircolors'
```
设置 Terminal 支持 256 色，vim .barshrc 并添加 export TERM=xterm-256color，这样 dircolors for GNU ls 算设置完成.别忘了先 source .bashrc .接下来下载 Solarized 的Gnome-Terminal 配色：
```
git clone git://github.com/sigurdga/gnome-terminal-colors-solarized.git
cd gnome-terminal-colors-solarized 
./set_dark.sh 或./set_light.sh
```
dark为浅蓝色背景，light为白色背景

### 改VIM配色
改完终端的配色，再改VIM的配色，只要把 solarized.vim 复制到 ~/.vim/colors/ 目录下就可以了下载地址为：
```
https://github.com/altercation/vim-colors-solarized
```
修改.vimrc：
```
syntax enable
set background=dark
colorscheme solarized
```
即可．







