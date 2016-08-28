title: golang之database/sql与go-sql-driver
date: 2016-08-28 10:38:43
tags:
- golang
- database/sql
- go-sql-driver
categories:
- golang

toc: true

---

上篇文章也有说道，golang的http,rpc,以及第三方的redigo,go-sql-driver是开发一个服务常见的四大组件，因此我是很推荐有时间可以看下上述四大组件，而且golang自带的http和rpc框架本身就是http和rpc很好的教程，而且第三方框架miekg/dns也是采用http框架的形式，所以看懂http，对快速看懂miekg/dns是很有帮助的；

![厦大美景](http://7xjnip.com1.z0.glb.clouddn.com/ldw-1612992717.jpg "")

redigo相对较小，看起来比较容易，但是必须好好学习下redis的网络传输协议；http协议看懂整体流程相对较简单，但是要完全看懂，需要一定时日，毕竟内容较多；而golang的rpc框架可以基于tcp和http，也是比较好看懂，主要是反射比较多，rpc关键用了http自带的gob数解析格式，可以顺便学习下gob是如何使用的；而数据库操作之前用的就是挺迷糊的，明明有两个包database/sql和go-sql-driver为什么就只调用了database/sql里面的接口，因此在看了database/sql和go-sql-driver代码之后，就恍然大悟，也写篇博客记录下；

# 前言

-----

这里先给出简单例子，说明下如何使用database/sql；
```
package main

import (
	"database/sql"
	"fmt"

	_ "github.com/go-sql-driver/mysql"
)

func main() {
	db, err := sql.Open("mysql", "root:root@/test")
	checkErr(err)
	rows, err := db.Query("select * from test")
	checkErr(err)
	var (
		id   uint64
		name string
	)
	for rows.Next() {
		err = rows.Scan(&id, &name)
		checkErr(err)
		fmt.Println(id, "->", name)
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
```
这个例子很简单，先实例化一个数据库实例，然后通过db实例的query方法查询test数据库中的数据；大家可以看到，并没有用到go-sql-driver这个驱动程序，这是为什么了？

首先给出两个结论:
1. database/sql是golang提供操作数据库的接口，但是有些内部方法需要调用驱动程序的接口；
2. go-sql-driver是符合database/sql接口的一套驱动程序，因此，真正进行数据库操作的接口是在go-sql-driver中实现的；

好，接下来，我们看下database/sql是如何调用go-sql-driver的接口的；

# database/sql与go-sql-driver

-----

我们先来看下，database/sql是如何注册驱动程序的，这个有点类似于linux虚拟文件系统，注册不同的文件系统，最后调用的就是相应文件系统的接口；
```
//database/sql/sql.go
var (
	driversMu sync.Mutex
	drivers   = make(map[string]driver.Driver)
)
/*-------------------------------------------------*/
func Register(name string, driver driver.Driver) {
	driversMu.Lock()
	defer driversMu.Unlock()
	if driver == nil {
		panic("sql: Register driver is nil")
	}
	if _, dup := drivers[name]; dup {
		panic("sql: Register called twice for driver " + name)
	}
	//将驱动放入map中
	drivers[name] = driver
}
/*--------------------------------------------------------*/
//go-sql-driver/mysql/driver.go
func init() {
	sql.Register("mysql", &MySQLDriver{})
}
```
从这个代码可以看出，向database/sql注册驱动，其实就是将驱动程序存入database/sql内部定义的一个map中；而init()函数是在包引入时首先执行的函数，因此我们在使用go-sql-driver时，就不用显式注册驱动，因为包引入时，就已经注册好；我们接下来看下如何获得一个数据库；

## 获取一个数据库

由上述例子程序可以看出，要操作数据库，必须先获取一个数据库实例db，代码如下:
```
//database/sql/sql.go
func Open(driverName, dataSourceName string) (*DB, error) {
	driversMu.Lock()
	driveri, ok := drivers[driverName]
	driversMu.Unlock()
	if !ok {
		return nil, fmt.Errorf("sql: unknown driver %q (forgotten import?)", driverName)
	}
	db := &DB{
		driver:   driveri,
		dsn:      dataSourceName,
		openerCh: make(chan struct{}, connectionRequestQueueSize),
		lastPut:  make(map[*driverConn]string),
	}
	go db.connectionOpener()
	return db, nil
}
```

由这段代码，根据driverName获取驱动程序实例，然后封装成一个db实例返回，此时并没有一个连接存在；而是开启了一个goroutine来生产连接；我们来看下这个goroutine是怎么生产连接的；
```
func (db *DB) connectionOpener() {
	//这个channel的缓冲区大小为1000000
	for range db.openerCh {
		db.openNewConnection()
	}
}

// Open one new connection
func (db *DB) openNewConnection() {
	//这是database/sql第一次调用驱动的接口，获取一个真实的连接
	ci, err := db.driver.Open(db.dsn)
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.closed {
		if err == nil {
			ci.Close()
		}
		return
	}
	db.pendingOpens--
	if err != nil {
		db.putConnDBLocked(nil, err)
		return
	}
	//将从驱动获取的连接封装成driverConn
	dc := &driverConn{
		db: db,
		ci: ci,
	}
	//将新生成的driverConn放入空闲数组中
	if db.putConnDBLocked(dc, err) {
		db.addDepLocked(dc, dc)
		db.numOpen++
	} else {
		ci.Close()
	}
}
```
因此，在获取一个db实例的时候，同时也生成了一个生产连接的goroutine，这个goroutine阻塞在channel中，当需要连接的时候，直接向这个channel发送数据即可；那么什么时候会产生连接了？有以下两种情况:
1. 第一次调用ping函数的时候，会产生一个连接；
2. 当调用db.Exec或者db.Query等方法时，如果空闲数组中有连接，则直接获取，如果空闲数组中没有可用的连接，则会产生一个新的连接；

## ping函数

这里用ping函数来演示，如何通过向上述的goroutine发送数据，并产生一个连接，来，看下ping函数:
```
func (db *DB) Ping() error {
	//获取一个连接
	dc, err := db.conn(cachedOrNewConn)
	if err != nil {
		return err
	}
	//将连接放入空闲数组中
	db.putConn(dc, nil)
	return nil
}
```
ping这个函数很简单，调用db.conn获取一个连接，参数表示获取策略，可以是
1. cachedOrNewConn从空闲数组获取或者新新生成一个连接
2. alwaysNewConn总是从新生成一个连接

接下来，看下db.conn函数:
```
func (db *DB) conn(strategy connReuseStrategy) (*driverConn, error) {
	db.mu.Lock()
	if db.closed {
		db.mu.Unlock()
		return nil, errDBClosed
	}
	//如果策略可以从空闲连接数组中获取，且空闲连接大于0,则直接从空闲数组获取连接返回；
	numFree := len(db.freeConn)
	if strategy == cachedOrNewConn && numFree > 0 {
		conn := db.freeConn[0]
		copy(db.freeConn, db.freeConn[1:])
		db.freeConn = db.freeConn[:numFree-1]
		conn.inUse = true
		db.mu.Unlock()
		return conn, nil
	}
	//如果当前打开的连接数大于设定的最大连接数，则阻塞在connQequest这个channel上，
	//下文再揭晓什么时候往这个channel写数据
	if db.maxOpen > 0 && db.numOpen >= db.maxOpen {
		req := make(chan connRequest, 1)
		db.connRequests = append(db.connRequests, req)
		db.mu.Unlock()
		ret := <-req
		return ret.conn, ret.err
	}
	//如果空闲连接数组中没有可用连接，且当前打开连接数还没达到最大值，则直接生成一个连接；
	db.numOpen++ 
	db.mu.Unlock()
	ci, err := db.driver.Open(db.dsn)
	if err != nil {
		db.mu.Lock()
		db.numOpen-- // 获取失败，则当前连接数减一
		db.mu.Unlock()
		return nil, err
	}
	db.mu.Lock()
	//封装成driverConn
	dc := &driverConn{
		db: db,
		ci: ci,
	}
	db.addDepLocked(dc, dc)
	dc.inUse = true
	db.mu.Unlock()
	return dc, nil
}
```
从这个函数可以看出，并不是所有连接都是从之前提到的那个goroutine产生，这个db.conn也会直接调用driver.Open函数产生连接；接下来看下ping函数内部是如何把连接放入空闲连接数组中的；
```
func (db *DB) putConn(dc *driverConn, err error) {
	db.mu.Lock()
	if err == driver.ErrBadConn {
		db.maybeOpenNewConnections()
		db.mu.Unlock()
		dc.Close()
		return
	}
	added := db.putConnDBLocked(dc, nil)
	db.mu.Unlock()

	if !added {
		dc.Close()
	}
```
这个函数内部，如果传进来的err为driver.ErrBadConn，那么之前在调用db.conn时获取的是一个无效的连接，因此这里需要调用db.maybeOpenNewConnections()来产生新连接；这个函数后面分析，先来看下added := db.putConnDBLocked(dc, nil)
```
func (db *DB) putConnDBLocked(dc *driverConn, err error) bool {
	if db.maxOpen > 0 && db.numOpen > db.maxOpen {
		return false
	}
	//如果有goroutine阻塞在获取连接上，则将这个本应该放回空闲连接数组的连接
	//返回给那个goroutine
	if c := len(db.connRequests); c > 0 {
		req := db.connRequests[0]
		copy(db.connRequests, db.connRequests[1:])
		db.connRequests = db.connRequests[:c-1]
		if err == nil {
			dc.inUse = true
		}
		req <- connRequest{
			conn: dc,
			err:  err,
		}
		return true
	//否则将这个连接放入空闲数组中
	} else if err == nil && !db.closed && db.maxIdleConnsLocked() > len(db.freeConn) {
		db.freeConn = append(db.freeConn, dc)
		return true
	}
	return false
}
```
ok，到这里，可以做个小结
* 当某个goroutine需要一个连接的时候，首先查看空闲连接数组中是否有可用连接，如果有，则直接从空闲数组中获取；如果空闲数组中没有可用的连接，则需要判断当前打开的连接数是否超出设定的最大值，如果是，则当前goroutine阻塞；如果当前打开的连接数并没有大于设定的最大值，则直接生产一个连接返回；
* 当某个goroutine结束数据库操作时，将当前使用的连接放入空闲连接数组中，这时需要进行判断，是否有某个goroutine阻塞在获取连接上，如果有，则将当前的连接直接返回给阻塞的goroutine，如果没有goroutine阻塞在获取连接上，则可以直接放入空闲连接数组即可；

之前还提到一个问题，就是当在putConn函数中，如果传入的是一个badConn，那么这时可能要生成新的连接；道理也很简单，因为如果某个goroutine阻塞在获取连接上，那么可能因为这个连接未及时调用putConn而阻塞更久；

我们来看下这个db.maybeOpenNewConnections()函数
```
func (db *DB) maybeOpenNewConnections() {
	//需要产生新的连接数量，db.pendingOpens是正在生成连接的数量
	numRequests := len(db.connRequests) - db.pendingOpens
	if db.maxOpen > 0 {
		numCanOpen := db.maxOpen - (db.numOpen + db.pendingOpens)
		if numRequests > numCanOpen {
			numRequests = numCanOpen
		}
	}
	for numRequests > 0 {
		db.pendingOpens++
		numRequests--
		//向db.openerCh发送数据，connectionOpener便会产生一个新连接
		db.openerCh <- struct{}{}
	}
}
```
到这里，才知道，原来一开始产生db的时候，新建的goroutine是在当连接出错时，用来生产连接的；

## db.Query方法

之前已经知道如何获取一个连接，接着我们可以用db.Query是方法是如何实现的；
```
func (db *DB) Query(query string, args ...interface{}) (*Rows, error) {
	var rows *Rows
	var err error
	for i := 0; i < maxBadConnRetries; i++ {
		rows, err = db.query(query, args, cachedOrNewConn)
		if err != driver.ErrBadConn {
			break
		}
	}
	if err == driver.ErrBadConn {
		return db.query(query, args, alwaysNewConn)
	}
	return rows, err
}
```
这个函数，最终调用的是db.query()函数
```
//database/sql/sql.go
func (db *DB) query(query string, args []interface{}, strategy connReuseStrategy) (*Rows, error) {
	//调用db.conn获取连接，如果出错，则回到Query方法的for循环中
	ci, err := db.conn(strategy)
	if err != nil {
		return nil, err
	}

	return db.queryConn(ci, ci.releaseConn, query, args)
}
/*-------------------------------------------------------------*/
func (db *DB) queryConn(dc *driverConn, releaseConn func(error), query string, args []interface{}) (*Rows, error) {
	//driver.Queryer是一个接口，只有query方法；从驱动中获取的
	//连接必须实现Query方法，
	if queryer, ok := dc.ci.(driver.Queryer); ok {
		dargs, err := driverArgs(nil, args)
		if err != nil {
			releaseConn(err)
			return nil, err
		}
		dc.Lock()
		//调用go-sql-driver中连接的Query方法
		rowsi, err := queryer.Query(query, dargs)
		dc.Unlock()
		if err != driver.ErrSkip {
			if err != nil {
				releaseConn(err)
				return nil, err
			}
			// 将结果封装成Rows
			rows := &Rows{
				dc:          dc,
				releaseConn: releaseConn,
				rowsi:       rowsi,
			}
			return rows, nil
		}
	}
	...省去一些代码...
}
```
从queryConn函数可以看出，db.Query方法最终调用go-sql-driver驱动中mysqlConn.Query方法，最后将结果封装成Rows，返回给客户端；最后看下go-sql-driver的mysqlConn.Query方法
```
func (mc *mysqlConn) Query(query string, args []driver.Value) (driver.Rows, error) {
	if mc.netConn == nil {
		errLog.Print(ErrInvalidConn)
		return nil, driver.ErrBadConn
	}
	// 发送sql语句请求，comQuery是查询类型
	err := mc.writeCommandPacketStr(comQuery, query)
	if err == nil {
		// 读取结果
		var resLen int
		resLen, err = mc.readResultSetHeaderPacket()
		if err == nil {
			rows := new(textRows)
			rows.mc = mc

			if resLen == 0 {
				// no columns, no more data
				return emptyRows{}, nil
			}
			// Columns
			rows.columns, err = mc.readColumns(resLen)
			return rows, err
		}
	}
	return nil, err
}
```
可以看到，对于实现database/sql接口的驱动，操作的是真实的数据库，然后将结果返回给database/sql中的方法；其他方法类似，这里不一一分析；

# 总结

这篇文章主要分析了golang的database/sql模块是如何调用驱动中定义的方法；了解这些之后，对于使用database/sql将会更加得心应手，以及在驱动出现错误时，可以更快速的定位到错误；

之前看到很多地方都有用到protobuf，因此决定好好研究下这个框架，下次理解透之后，在发出来.




