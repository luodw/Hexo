title: 平衡二叉树(avl)分析与实现
date: 2015-11-14 15:35:22
tags:
- avl
categories:
- data_structure
toc: true

---

继上次二叉搜索树分析之后，今天分析下平衡二叉树．平衡二叉树是二叉搜索树进化而来的，因为二叉搜索树的期望高度为log2n，各项操作的时间复杂度的期望也是log2n，但是在极端情况下，二叉搜索树将退化为链表（有序插入时），这时的时间复杂度将退化为n，所以二叉搜索树实际用的并不是很多，实际中用的较多的是平衡二叉树和红黑树．例如C++STL中的map,set,mutilset,mutilmap的底层都是用红黑树实现的．

平衡二叉树的主要性质：它是一棵空树或者它的左右子树的高度差的绝对值不超过１，并且左右两棵子树都是平衡二叉树．

平衡二叉树的实现:平衡二叉树本质上也是一棵二叉搜索树，所以如果只是读取的话，是不会改变平衡二叉树的，所以二叉搜索树的读取方法可以直接用在平衡二叉树上，但是插入和删除会改变平衡二叉树的左右子树的高度，导致左右子树的高度差大于等于２，这时树就不平衡．AVL树是通过旋转来实现插入和删除之后的平衡．

对于子树的旋转网上有很多博客讲解，我就不多说了，我这里引用其中一篇博客的图片，因为我觉得那篇博客的图片画的很好，图片来自[C小加的博客](http://www.cppblog.com/cxiaojia/archive/2012/08/20/187776.html "")
![avl旋转四种情况](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_035.png "")

1. 6节点的左子树3节点高度比右子树7节点大2，左子树3节点的左子树1节点高度大于右子树4节点，这种情况成为左左。
2. 6节点的左子树2节点高度比右子树7节点大2，左子树2节点的左子树1节点高度小于右子树4节点，这种情况成为左右。
3. 2节点的左子树1节点高度比右子树5节点小2，右子树5节点的左子树3节点高度大于右子树6节点，这种情况成为右左。
4. 2节点的左子树1节点高度比右子树4节点小2，右子树4节点的左子树3节点高度小于右子树6节点，这种情况成为右右。

从图2中可以可以看出，1和4两种情况是对称的，这两种情况的旋转算法是一致的，只需要经过一次旋转就可以达到目标，我们称之为单旋转。2和3两种情况也是对称的，这两种情况的旋转算法也是一致的，需要进行两次旋转，我们称之为双旋转。

AVL树就这四种旋转情况，具体怎么旋转，就百度了．我主要是分析下如何实现．

# AVL树定义

----

AVL树节点主要由值，高度，左子树，右子树和父亲组成，那篇博客中没有定义父亲，所以在实现删除的时候会出错．
```
typedef int ValueType;
struct avl_node
{
	ValueType data;
	int height;
	struct avl_node *parent;
	struct avl_node *left;
	struct avl_node *right;
};
typedef struct avl_node* node;
```

# 两个辅助函数

---

这里定义两个函数，用于求子树的高度和取两个子树高度的最大值．
```
static int Height(node p)
{
	if(p==NULL)
		return -1;
	else
		return p->height;
}

static int Max(int lhs,int rhs)
{
	return lhs>rhs?lhs:rhs;
}
```
这里定义NULL节点的高度为-1，这样以来，叶子节点的高度就为0．

# 四种情况下的旋转函数

----

再次从C小加的博客中拿了两张图，用于说明旋转函数实现:
![左左情况下旋转示意图](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_036.png "")
如上图，k2的左子树比右子树高２，所以不平衡，我们需要把k1提到k2的位置，然后k2下降到k1的右子树，最后还有把k1的右子树放到k2的左子树即可．至于y为什么要放到k2的左子树了？因为y大于k1小于k2，当k1升到k2位置时，k1已经有右子树k2，所以只能把y放到k2的左子树，符合二叉搜索树性质．代码如下:
```
static node SingleRotateLeft(node &p1)
{
	node p2=p1->left;//找到p1的左子树
	p2->parent=p1->parent;//p2的父亲转交给p1
	p1->parent=p2;//p1的父亲变成了p2
	p1->left=p2->right;//将p2的右子树移至p1的左子树
	if(p2->right!=NULL)//如果p2的右子树非空，则还要建立父亲关系
		p2->right->parent=p1;
	p2->right=p1;//建立p2和p1的关系
	//更新p1和p2的高度，因为p2高度依赖p1，所以先更新p1
	p1->height=Max(Height(p1->left),Height(p1->right))+1;
	p2->height=Max(Height(p2->left),Height(p2->right))+1;
	return p2;
}
//右右情况的旋转和左左的对称，所以原理类似
static node SingleRotateRight(node &p1)
{
	node p2=p1->right;
	p2->parent=p1->parent;
	p1->parent=p2;
	p1->right=p2->left;
	if(p2->left!=NULL)//must
		p2->left->parent=p1;
	p2->left=p1;
	p1->height=Max(Height(p1->left),Height(p1->right))+1;
	p2->height=Max(Height(p2->left),Height(p2->right))+1;
	return p2;
}
```

还有左右和右左旋转情况，图示如下:
![左右情况下的旋转](http://7xjnip.com1.z0.glb.clouddn.com/ldw-选区_037.png "")

左右情况下的旋转，先以k3的左子树为根节点执行一次左左旋转，然后以k3的根节点，执行一次右右旋转即可．右左情况和左右对称．
```
static node DoubleRotateLR(node &p1)
{
	p1->left=SingleRotateRight(p1->left);
	return SingleRotateLeft(p1);
}

static node DoubleRotateRL(node &p1)
{
	p1->right=SingleRotateLeft(p1->right);
	return SingleRotateRight(p1);
}
```

# AVL树插入操作

----

AVL树插入时，会破坏平衡性，所以没当插入一个数据时，都要从插入点往上，一步一步检测是否出现两棵子树高度差等于2，如果等于2，则要做相应的旋转．
```
static node Insert(node root,node parent,ValueType x)
{
	//判断是否为根节点，以及当判断是否为插入点
	if(root==NULL)
	{
		root=(node)malloc(sizeof(struct avl_node));
		root->data=x;
		root->height=0;
		root->left=root->right=NULL;
		root->parent=parent;
	}
	//当插入值比当前节点值小时，则往左子树插入
	else if(x<root->data)
	{
		root->left=Insert(root->left,root,x);//递归插入
		if(Height(root->left)-Height(root->right)==2)//判断子树是否平衡
		{
			if(x<root->left->data)//插入值小于当前节点的左节点的值，则为左左情况
				root=SingleRotateLeft(root);
			else//否则为左右情况
				root=DoubleRotateLR(root);
		}
	}else if(x>root->data)//插入值比当前节点大时，往右子树插入
	{
		root->right=Insert(root->right,root,x);
		if(Height(root->right)-Height(root->left)==2)
		{
			if(x>root->right->data)
				root=SingleRotateRight(root);
			else
				root=DoubleRotateRL(root);
		}
	}
	//更新当前节点的高度
	root->height=Max(Height(root->left),Height(root->right))+1;
	return root;
}
```

# AVL树的删除

----

AVL树插入操作相对较简单，但是AVL删除操作就相对复杂了．AVL树删除操作也要分为四种情况，
1. 删除节点两个子树都非空
2. 删除节点左子树非空，右子树空
3. 删除节点右子树非空，左子树空
4. 删除节点左右子树都为空
```
void delete_node(node root,ValueType x)
{
	if(root==NULL)//空树直接返回
		return;
	if(x<root->data)//删除值小于当前节点，说明删除节点在当前节点左侧
	{
		delete_node(root->left,x);
		if(Height(root->right)-Height(root->left)==2)
		{
			if(root->right->left!=NULL && (Height(root->right->left)>Height(root->right->right)) )
				root=DoubleRotateRL(root);
			else
				root=SingleRotateRight(root);
		}
	}
	else if(x>root->data)//删除节点在当前节点右侧
	{
		delete_node(root->right,x);
		if(Height(root->left)-Height(root->right)==2)
		{
			if(root->left->right!=NULL && (Height(root->left->right)>Height(root->left->left)))
				root=DoubleRotateLR(root);
			else
				root=SingleRotateLeft(root);
		}
	}
	else//找到删除节点
	{
		if(root->left && root->right)
		{//对于左右子树都不为空的情况
			node temp=root->right;
			while(temp->left!=NULL) temp=temp->left;
			int data=temp->data;
			int height=temp->height;
			delete_node(root,temp->data);//删除后继节点
			root->data=data;//再将后继节点的值赋给当前节点
			root->height=height;
		}
		else
		{//只有一棵子树或者两棵子树都为空
			if(root->left && !root->right)
			{//左子树非空，右子树空，则让左子树和父亲建立关系即可
			//也就是跳过当前节点
				if(root->data<root->parent->data){
					root->parent->left=root->left;
					root->left->parent=root->parent;
				}
				else{
					root->parent->right=root->left;
					root->left->parent=root->parent;
				}
			}
			else if(!root->left && root->right)
			{//右子树空，左子树非空
				if(root->data<root->parent->data){
					root->parent->left=root->right;
					root->right->parent=root->parent;
				}
				else{
					root->parent->right=root->right;
					root->right->parent=root->parent;
				}
			}
			else
			{//左右子树都为空,即为叶子节点，则直接将父亲相应节点设为空即可
				if(root->data<root->parent->data)
					root->parent->left=NULL;
				else
					root->parent->right=NULL;
			}
			free(root);//删除当前节点
			root=NULL;//当前节点指针为空
		}
	}
	if(root==NULL) return; //这是必须的，因为删除节点时，这个节点的指针被设置为NULL
	//如果直接执行下面那行，会报错，因为引用一个无效内存．
	root->height=Max(Height(root->left),Height(root->right))+1;
	return;
}
```
在编写这个平衡二叉树时，一定要判断是否为空，因为之前没判断，导致经常core dump，引用了一块无效的内存，例如旋转时，判断if(p2->left!=NULL)，以及删除函数中，判断root==NULL等等．

平衡二叉树的其他操作和二叉搜索树一样，可以直接拿来用．














