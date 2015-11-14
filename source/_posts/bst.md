title: 二叉搜索树分析与实现
date: 2015-11-12 17:38:23
tags:
- bst
categories:
- data_structure
toc: true

---

最近在看STL源码分析，看到关联容器时，被红黑树的复杂给卡住了，所以打算这几天好好学习下树这个数据结构．当初学数据结构时，对树也是一知半解，所以趁这个机会，好好掌握树，找工作时，也是经常被到，学好树还是很有必要的．

平常使用的树就属二叉搜索树，更上一级的就是二叉搜索树的升级版平衡二叉树(AVL)和红黑树(rbtree)，如果有研究mysql存储，可能还需对B-tree有一定的了解．这篇文章就对最简单的二叉搜索树做个介绍．

# 二叉搜索树节点

-------

二叉搜索树的节点有数据域，父节点，左节点和右节点组成，这也是一颗完整二叉树节点拥有的成员变量，定义如下:
```
//树存储的数据类型
typedef int ValueType;
struct bst_node
{
	ValueType value;
	struct bst_node *parent;
	struct bst_node *left;
	struct bst_node *right;
};//树节点类型
typedef struct bst_node* node;
```
如果要定义成能存储多种数据类型，可以将数据域定义为void*类型，然后在插入数据时，然后可以定义一个比较器，用于插入数据时，判断数据大小．

# 二叉树的插入

---

二叉树插入时，需要考虑树是否为空，如果是，则插入的节点则为根节点；如果不是，则先找到插入节点的父节点，再将插入值和这个父节点比较:
1. 如果插入值比父节点的值小，则插入值插入父节点的左子节点；
2. 如果插入值比父节点的值大，则插入值插入父节点的右子节点；

我的实现如下:
```
void insert_node(node *root,ValueType data)
{
	//初始化节点
	node p=(node)malloc(sizeof(struct bst_node));
	p->value=data;
	p->parent=NULL;
	p->left=NULL;
	p->right=NULL;
	//如果是空树，则新插入的节点为根节点
	if((*root)==NULL)
	{
		*root=p;
		return;
	}

	node parent=(*root);
	node tmp=(*root);
	//迭代找打要插入的位置
	while(tmp!=NULL)
	{
		parent=tmp;
		if(data==tmp->value)
			return;
		if(data<tmp->value)
			tmp=tmp->left;
		else
			tmp=tmp->right;
	}
　　　　//插入节点
	p->parent=parent;
	if(data<parent->value)
		parent->left=p;
	else
		parent->right=p;

}
```
对于树的实现有递归和迭代两种方法，我的建议是除了输出时用递归，其他用迭代，毕竟迭代思路更清晰，递归思路曲折．

# 查找最大最小值

---

1. 当查找某个节点的最大值时，只需要从这个节点开始，一直往右即可．
2. 当查找某个节点的最小值时，只需要从这个节点开始，一直往左即可．
```
node max_node(node root)
{
	if(root==NULL)
		return root;
	while(root->right!=NULL)
		root=root->right;
	return root;
}

node min_node(node root)
{
	if(root==NULL)
		return root;
	while(root->left!=NULL)
		root=root->left;
	return root;
}
```

# 查找某个给定值的节点

---

查找某个给定值的节点时，思路和插入时类似，根据数值和根节点的比较，如果查找数值比根节点数值小，则往左迭代，否则往右迭代．
```
node find_node(node root,ValueType data)
{
	if(root==NULL)
		return NULL;
	node parent=root,tmp=root;
	while(tmp!=NULL)
	{
		parent=tmp;
		if(tmp->value==data)
			return tmp;
		else
		{
			if(data<tmp->value)
				tmp=tmp->left;
			else
				tmp=tmp->right;
		}
	}
	return NULL;
}
```
如果找到该节点，则返回该节点，否则返回NULL，用于调用判断是否有这个节点

# 某个节点的前驱

---

当查找某个节点的前驱节点时，如果是空树，则返回空；如果有左子树，则返回左子树的最大值作为前驱；如果没有左子树，又要分为两种情况
1. 如果删除的是根节点，则没有前驱；
2. 如果普通内部节点，往上找到某个节点是其父节点的右节点时，则这个节点的父节点就是这个节点的前驱
```
node predecessor(node p)
{
	if(p==NULL)
		return NULL;
	if(p->left)
		return max_node(p->left);
	else
	{
		if(p->parent==NULL)
			return NULL;
		while(p){
			if(p->parent->right==p)
				break;
			p=p->parent;
		}
		return p->parent;
	}
}
```
后继节点思路和前驱节点类似．

# 删除某个节点

---

删除某个节点时，情况比较复杂，首先判断是否为空树，如果是，则返回0，表示删除失败；如果不为空，则有以下４中情况:
1. 删除节点两个子节点都为空，即为叶子节点．先要判断是否为根节点，如果是，则回收这个节点，并且根节点指针为空；如果不是根节点，则直接把这个删除节点的父节点相应子树设为空，再删除这个节点
2. 删除节点只有左节点，先要判断删除节点是否为根节点，如果是，则删除这个节点，并且把这个节点的左子树设为根节点；如果不是，则把这个节点用其左子树代替
3. 删除节点只有右节点，先要判断删除节点是否为根节点，如果是，则删除这个节点，并且把这个节点的右子树设为根节点；如果不是，则把这个节点用其右子树代替
4. 删除节点两个子节点都不为空，先删除这个删除节点的后继节点，然后把后继节点的值赋给删除节点即可．

对于第四点，主要因为是这个节点的后继节点肯定没有左子树，如果有左子树，则删除节点的后继节点就是左子树了，则删除这个后继节点只需要执行上述一种情况．

代码如下:
```
int delete_node(node *root,ValueType data)
{
	node p=find_node((*root),data);
	//如果没找到，返回空节点
	if(p==NULL)
		return 0;
	ValueType temp;
	//case1  删除节点的两个子树同时为空
	if(p->left==NULL && p->right==NULL)
	{
		//如果只有一个节点，即根节点
		if(p->parent==NULL)
		{
			free(p);
			(*root)=NULL;
		}else//普通叶子节点
		{
			//删除节点是父节点的左孩子
			if(p->value<p->parent->value)
				p->parent->left=NULL;
			else//删除节点是父节点的右孩子
				p->parent->right=NULL;
			free(p);
		}
	}
	//case2  删除节点只有右孩子
	else if(p->left==NULL && p->right)
	{
		p->right->parent=p->parent;
		if(p->parent==NULL)
			*root=p->right;
		else if(p->value < p->parent->value)
			p->parent->left=p->right;
		else
			p->parent->right=p->right;
		free(p);
	}
	//case3  删除节点只有左孩子
	else if(p->left && p->right==NULL)
	{
		p->left->parent=p->parent;
		if(p->parent==NULL)
			*root=p->left;
		else if(p->value < p->parent->value)
			p->parent->left=p->left;
		else
			p->parent->right=p->left;
		free(p);
	}
	//case4  删除节点两个子节点都不为空
	else
	{
		node q=successor(p);
		temp=q->value;
		delete_node(root,temp);
		p->value=temp;
	}
	return 1;
}
```
# 实现代码

---

本来，我只实现了二叉搜索树存储整型值，后来为了拓展用二叉树来存储一个对象，所以将节点值域改为void*类型，这样就可以存储任何类型数据．但是对象类必须实现重载<和+符号，因为代码有比较两个对象的大小．本来打算写个仿函数，但是这样要修改更多的代码．实现代码如下:
```
#include<stdio.h>
#include<stdlib.h>
#include<string>

using std::string;
//树存储的数据类型
//typedef int ValueType;

struct people{
	string name;
	int age;
	bool operator< (struct people &peo)
	{
		return age<peo.age;
	}
	bool operator== (struct people &peo)
	{
		return age==peo.age;
	}
};
typedef struct people peo;
typedef peo* ValueType;

struct bst_node
{
	void* value;
	struct bst_node *parent;
	struct bst_node *left;
	struct bst_node *right;
};//树节点类型
typedef struct bst_node* node;

void insert_node(node *root,ValueType data)
{
	//初始化节点
	node p=(node)malloc(sizeof(struct bst_node));
	p->value=data;
	p->parent=NULL;
	p->left=NULL;
	p->right=NULL;
	//如果是空树，则新插入的节点为根节点
	if((*root)==NULL)
	{
		*root=p;
		return;
	}

	node parent=(*root);
	node tmp=(*root);
	//迭代找打要插入的位置
	while(tmp!=NULL)
	{
		parent=tmp;
		if((*data)==*(ValueType)(tmp->value))
			return;
		if( (*data) < *(ValueType)(tmp->value))
			tmp=tmp->left;
		else
			tmp=tmp->right;
	}
             //插入节点
	p->parent=parent;
	if(*data<*(ValueType)(parent->value) )
		parent->left=p;
	else
		parent->right=p;

}
node max_node(node root)
{
	if(root==NULL)
		return root;
	while(root->right!=NULL)
		root=root->right;
	return root;
}

node min_node(node root)
{
	if(root==NULL)
		return root;
	while(root->left!=NULL)
		root=root->left;
	return root;
}

void print_bst(node root)
{
	if(root==NULL)
		return;
	print_bst(root->left);
	ValueType p=(struct people*)root->value;
	printf("%s \t %d \n ",(p->name).c_str(),p->age);
	print_bst(root->right);
}

node find_node(node root,ValueType data)
{
	if(root==NULL)
		return NULL;
	node parent=root,tmp=root;
	while(tmp!=NULL)
	{
		parent=tmp;
		if((*data)==*(ValueType)(tmp->value))
			return tmp;
		else
		{
			if( (*data) < *(ValueType)(tmp->value))
				tmp=tmp->left;
			else
				tmp=tmp->right;
		}
	}
	return NULL;
}

node predecessor(node p)
{
	if(p==NULL)
		return NULL;
	if(p->left)
		return max_node(p->left);
	else
	{
		if(p->parent==NULL)
			return NULL;
		while(p){
			if(p->parent->right==p)
				break;
			p=p->parent;
		}
		return p->parent;
	}
}


node successor(node p)
{
	if(p==NULL)
		return NULL;
	if(p->right)
		return min_node(p->right);
	else
	{
		if(p->parent==NULL)
			return NULL;
		while(p){
			if(p->parent->left==p)
				break;
			p=p->parent;
		}
		return p->parent;
	}
}

int delete_node(node *root,ValueType data)
{
	node p=find_node((*root),data);
	//如果没找到，返回空节点
	if(p==NULL)
		return 0;
	//case1  删除节点的两个子树同时为空
	if(p->left==NULL && p->right==NULL)
	{
		//如果只有一个节点，即根节点
		if(p->parent==NULL)
		{
			free(p);
			(*root)=NULL;
		}else//普通叶子节点
		{
			//删除节点是父节点的左孩子
			if(*(ValueType)(p->value)<*(ValueType)(p->parent->value))
				p->parent->left=NULL;
			else//删除节点是父节点的右孩子
				p->parent->right=NULL;
			free(p);
		}
	}
	//case2  删除节点只有右孩子
	else if(p->left==NULL && p->right)
	{
		p->right->parent=p->parent;
		if(p->parent==NULL)
			*root=p->right;
		else if(*(ValueType)(p->value)<*(ValueType)(p->parent->value))
			p->parent->left=p->right;
		else
			p->parent->right=p->right;
		free(p);
	}
	//case3  删除节点只有左孩子
	else if(p->left && p->right==NULL)
	{
		p->left->parent=p->parent;
		if(p->parent==NULL)
			*root=p->left;
		else if(*(ValueType)(p->value)<*(ValueType)(p->parent->value))
			p->parent->left=p->left;
		else
			p->parent->right=p->left;
		free(p);
	}
	//case4  删除节点两个子节点都不为空
	else
	{
		node q=successor(p);
		ValueType temp=(ValueType)q->value;
		delete_node(root,temp);
		p->value=temp;
	}
	return 1;
}


int main(void)
{
	int i=0;
	node root=NULL,tmp=NULL;
	peo arr[5]={{"jason",8},{"tom",3},{"bob",5},{"helly",7},{"Lily",1}};
	for(i=0;i<5;i++)
		insert_node(&root,arr+i);
	print_bst(root);
	printf("\n");
              printf("The max node is=%s\n",(ValueType(max_node(root)->value))->name.c_str());
	printf("The min node is=%s \n",(ValueType(min_node(root)->value))->name.c_str());
              peo v={"tom",3};
	node p=find_node(root,&v);
	tmp=predecessor(p);
	if(tmp==NULL)
		printf("The node has no predecessor!\n");
	else
		printf("The predecessor of 3 is=%s\n",( (ValueType)(tmp->value) )->name.c_str());
	tmp=successor(p);
	if(tmp==NULL)
		printf("The node has no successor!\n");
	else
		printf("The successor of 3 is=%s\n",( (ValueType)(tmp->value) )->name.c_str());
	int flag=delete_node(&root,&v);
	if(!flag)
		printf("There is no node of 3!\n");
	else
		print_bst(root);
	return 0;
}

```
运行结果如下:
```
charles@charles-Lenovo:~/mydir/algorithm$ g++ bst2.cc -o bst2
charles@charles-Lenovo:~/mydir/algorithm$ ./bst2
Lily 	 1 
tom 	 3 
bob 	 5 
helly 	 7 
jason 	 8 

The max node is=jason
The min node is=Lily 
The predecessor of 3 is=Lily
The successor of 3 is=bob
Lily 	 1 
bob 	 5 
helly 	 7 
jason 	 8 
charles@charles-Lenovo:~/mydir/algorithm$ 
```
可以看到二叉树是按年龄从小到大输出这些对象，以及其他操作也是和普通整型时，输出的一样．
