title: nsqd执行解析
date: 2017-04-14 20:11:45
tags:
- nsqd
categories:
- nsq

toc: true

---

这几天因为实验室原因，接触了kafka，又因为这个kafka，我就记起来早在去年看NSQ消息队列，而且之前也忘了写篇关于nsqd的原理介绍，因此这两天看了下nsqd代码，也就有了这篇文章。nsqd用golang语言编写，整体的框架以及代码都写得很棒，很好发挥了golang中goroutine和channel的结合使用，看nsq代码可以学习如何更优雅的使用golang，就如看redis可以学习原来c语言还可以写的那么优雅。

nsqd是NSQ中最重要的组件，接收生产者的消息以及给消费者发送消息都由nsqd完成。因此，这篇文章主要由下面三个部分：
1. NSQ再介绍
2. 生产者如何投递消息；
3. 消费者如何接收消息；
4. 总结；

【版权声明】博客内容由罗道文的私房菜拥有版权，允许转载，但请标明原文链接[http://luodw.cc/2017/04/14/nsqd/#more](http://luodw.cc/2017/04/14/nsqd/#more "")

# NSQ再介绍

----

因为上篇关于NSQ的文章距离现在挺久远的，因此这里再次介绍下NSQ。先给出NSQ的拓扑图：
![NSQ拓扑](http://7xjnip.com1.z0.glb.clouddn.com/ldw-3139862022.jpg "")

在拓扑图中，NSQ主要由三个组件组成:
1. nsqlookupd　该组件提供服务发现，消费者需要先连接nsqlookupd服务获取nsqd的地址，然后再连接nsqd。
2. nsqd　该组件是NSQ提供消息处理和转发的最核心组件。
3. nsqadmin　该组件是一个web服务器，提供查看NSQ整体信息的web ui界面。

由拓扑图也可以看出，nsqd通过心态机制与nsqlookupd上报状态以及topic和channel信息。当向某个topic发布一个消息时，producer会同时连上所有的nsqd，然后随机选择一个nsqd发送消息；而consumer通过nsqlookupd获取到所有nsqd地址后，再向所有nsqd发起连接；当producer随机向某个nsqd发送消息时，该nsqd则将消息返回给consumer。

接下来看下单台nsqd是如何处理消息的，这里引用官网的一个动图：
![nsqd消息处理](https://f.cloud.github.com/assets/187441/1700696/f1434dc8-6029-11e3-8a66-18ca4ea10aca.gif "")

当producer向nsqd某个topic发送一条消息时，该消息会被复制发送到该topic下的所有channel。当某个channel对应着多个client时，这时channel随机选择一个client，并由该client处理该消息。

由上述可以看出，为了提高性能，NSQ多两次使用负载均衡，例如producer发送消息时，随机选择一个nsqd服务接收消息以及channel在多个client中随机选择一个处理消息。

# 生产者如何投递消息

---

通过对NSQ有了整体认识之后，接下来详细介绍下生产者如何把消息投递给client。nsqd的启动和nsqlookupd类似，也是通过开源框架
> "github.com/judwhite/go-svc/svc"

优雅启动和退出，在nsqd的Main函数中开启了监听处理tcp和http两个服务的goroutine，与nsqlookupd不同的是，nsqd在Main函数中除了上述两个goroutine，还开启了其余三个goroutine
1. lookupLoop　保持与nsqlookupd心跳连接，上报信息；
2. queueScanLoop　扫描和处理InFlightQueue和DeferredQueue；
3. statsdLoop　需要配置状态服务地址之后才开启；

nsqd在开启之后，对于监听tcp的服务，每当有一个连接，tcp服务则开启一个goroutine处理该客户端，代码如下:
```golang
func TCPServer(listener net.Listener, handler TCPHandler, l app.Logger) {
	for {
		clientConn, err := listener.Accept()
	    /* ....省略....*/
		go handler.Handle(clientConn)
	}
```

而在Main函数中传递给这个函数的参数handler，为实现了Handle接口的结构体tcpServer，而在tcpServer.Handle函数中，最终调用protocol.IOLoop(clientConn)函数进行具体的处理，接下来看下这个函数
```golang
func (p *protocolV2) IOLoop(conn net.Conn) error {
    for {
		if client.HeartbeatInterval > 0 {
			client.SetReadDeadline(time.Now().Add(client.HeartbeatInterval * 2))
		} else {
			client.SetReadDeadline(zeroTime)
		}
        /* .....省略......*/
		line, err = client.Reader.ReadSlice('\n')
		// trim the '\n'
		line = line[:len(line)-1]
		// optionally trim the '\r'
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
        /* 解析出producer投递消息参数*/
		params := bytes.Split(line, separatorBytes)
        /* .....省略......*/
		var response []byte
        /* 在p.Exec函数中根据命令执行具体函数*/
		response, err = p.Exec(client, params)

		if response != nil {
            /* 将命令执行成功与否返回给用户 */
			err = p.Send(client, frameTypeResponse, response)
			if err != nil {
				err = fmt.Errorf("failed to send response - %s", err)
				break
			}
		}
	}
    /* 客户端出问题或者退出，则上面循环也将退出 */
	p.ctx.nsqd.logf("PROTOCOL(V2): [%s] exiting ioloop", client)
	conn.Close()
	close(client.ExitChan)
	if client.Channel != nil {
		client.Channel.RemoveClient(client.ID)
	}

	return err
}
```

上述IOLoop循环就是producer连接上nsqd之后，不断处理消息的代码段。对于producer，一个最简单的命令pub发送消息，先来看下p.Exec函数
```golang
func (p *protocolV2) Exec(client *clientV2, params [][]byte) ([]byte, error) {
	if bytes.Equal(params[0], []byte("IDENTIFY")) {
		return p.IDENTIFY(client, params)
	}
	err := enforceTLSPolicy(client, p, params[0])
	if err != nil {
		return nil, err
	}
	switch {
	case bytes.Equal(params[0], []byte("FIN")):
		return p.FIN(client, params)
	case bytes.Equal(params[0], []byte("RDY")):
		return p.RDY(client, params)
	case bytes.Equal(params[0], []byte("REQ")):
		return p.REQ(client, params)
	case bytes.Equal(params[0], []byte("PUB")):
		return p.PUB(client, params)
	case bytes.Equal(params[0], []byte("MPUB")):
		return p.MPUB(client, params)
	case bytes.Equal(params[0], []byte("DPUB")):
		return p.DPUB(client, params)
	case bytes.Equal(params[0], []byte("NOP")):
		return p.NOP(client, params)
	case bytes.Equal(params[0], []byte("TOUCH")):
		return p.TOUCH(client, params)
	case bytes.Equal(params[0], []byte("SUB")):
		return p.SUB(client, params)
	case bytes.Equal(params[0], []byte("CLS")):
		return p.CLS(client, params)
	case bytes.Equal(params[0], []byte("AUTH")):
		return p.AUTH(client, params)
	}
	return nil, protocol.NewFatalClientErr(nil, "E_INVALID", fmt.Sprintf("invalid command %s", params[0]))
}
```

由这个Exec函数可知，nsqd的tcp协议只支持上述12个命令，而大家最熟悉的莫过于PUB和SUB，即发布和订阅。对于producer，我么重点看下PUB这个命令：
```golang
func (p *protocolV2) PUB(client *clientV2, params [][]byte) ([]byte, error) {
    /* 读取topic名称，即第二个参数　*/
	topicName := string(params[1])
	if !protocol.IsValidTopicName(topicName) {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_TOPIC",
			fmt.Sprintf("PUB topic name %q is not valid", topicName))
	}
    /* 读取消息体的长度*/
	bodyLen, err := readLen(client.Reader, client.lenSlice)
	if err != nil {
		return nil, protocol.NewFatalClientErr(err, "E_BAD_MESSAGE", "PUB failed to read message body size")
	}
    /* 读取消息体 */
	messageBody := make([]byte, bodyLen)
	_, err = io.ReadFull(client.Reader, messageBody)
	if err != nil {
		return nil, protocol.NewFatalClientErr(err, "E_BAD_MESSAGE", "PUB failed to read message body")
	}

	if err := p.CheckAuth(client, "PUB", topicName, ""); err != nil {
		return nil, err
	}
    /* 获取topic实例 */
	topic := p.ctx.nsqd.GetTopic(topicName)
	/* 将消息体封装成message实例 */
    msg := NewMessage(topic.GenerateID(), messageBody)
	/* 向目标topic投递消息 */
    err = topic.PutMessage(msg)
	if err != nil {
		return nil, protocol.NewFatalClientErr(err, "E_PUB_FAILED", "PUB failed "+err.Error())
	}
	return okBytes, nil
}
```

对于这个函数，由两点需要说明，
1. 首先关于NSQ的tcp协议，可以参考[NSQ官网](http://nsq.io/clients/tcp_protocol_spec.html "")，这里给出PUB命令的协议如下:
```
PUB <topic_name>\n (注:这个\n，其实是空格，这里表示这两行换行)
[ 4-byte size in bytes ][ N-byte binary data ]

<topic_name> - a valid string (optionally having #ephemeral suffix)
```
2. 对于上述GetTopic函数，如果topic实例已经存在，则直接获取，否则新建一个，这也就说明了NSQ的topic是在投递第一条消息时创建的，这个GetTopic函数后面再分析。

ok，接下来继续分析向目标topic投递消息是如何完成的，即函数topic.PutMessage(msg)
```golang
func (t *Topic) PutMessage(m *Message) error {
	/* ....省略.... */
    err := t.put(m)
	if err != nil {
		return err
	}
	return nil
}
/* ------------------------------------------- */
func (t *Topic) put(m *Message) error {
	select {
	case t.memoryMsgChan <- m:
	default:
		b := bufferPoolGet()
		err := writeMessageToBackend(b, m, t.backend)
		bufferPoolPut(b)
		t.ctx.nsqd.SetHealth(err)
		if err != nil {
			t.ctx.nsqd.logf(
				"TOPIC(%s) ERROR: failed to write message to backend - %s",
				t.name, err)
			return err
		}
	}
	return nil
}
```

有Topic.put函数可以看出，nsqd优先把消息投递给内存channel（t.memoryMsgChan），当内存channel满了之后，则把消息append到磁盘文件中。而且这个t.memoryMsgChan可以通过参数mem-queue-size设置，默认为10000。而且从这个函数也可以看出，当把消息成功写入topic.memoryMsgChan或者追加到磁盘，消息投递成功。之后消息的处理，都交给了nsqd内部goroutine和channel之间的通信。那大家可能会好奇，消息写入topic.memoryMsgChan之后，在哪读取topic.memoryMsgChan处理消息了？下面要先来看下上述说的GetTopic函数:
```golang
func (n *NSQD) GetTopic(topicName string) *Topic {
	// most likely, we already have this topic, so try read lock first.
	n.RLock()
	t, ok := n.topicMap[topicName]
	n.RUnlock()
	if ok {
		return t
	}

	n.Lock()

	t, ok = n.topicMap[topicName]
	if ok {
		n.Unlock()
		return t
	}
	deleteCallback := func(t *Topic) {
		n.DeleteExistingTopic(t.name)
	}
	t = NewTopic(topicName, &context{n}, deleteCallback)
	n.topicMap[topicName] = t

	n.logf("TOPIC(%s): created", t.name)

	// release our global nsqd lock, and switch to a more granular topic lock while we init our
	// channels from lookupd. This blocks concurrent PutMessages to this topic.
	t.Lock()
	n.Unlock()
    /* 下面省略从nsqlookupd获取topic信息代码，因为这个nsqd实例可能是新加的机器，所以需要执行nsqlookupd查询 */
	return t
}
```

由代码可以验证，ＧetTopic函数是优先从已存在的topic中获取，如果请求的topic不存在，则新建一个topic。重点在哪个NewTopic函数，这个函数先代码如下：
```golang
func NewTopic(topicName string, ctx *context, deleteCallback func(*Topic)) *Topic {
	t := &Topic{
		name:              topicName,
		channelMap:        make(map[string]*Channel),
		memoryMsgChan:     make(chan *Message, ctx.nsqd.getOpts().MemQueueSize),
		exitChan:          make(chan int),
		channelUpdateChan: make(chan int),
		ctx:               ctx,
		pauseChan:         make(chan bool),
		deleteCallback:    deleteCallback,
		idFactory:         NewGUIDFactory(ctx.nsqd.getOpts().ID),
	}
	if strings.HasSuffix(topicName, "#ephemeral") {
		t.ephemeral = true
		t.backend = newDummyBackendQueue()
	} else {
		t.backend = diskqueue.New(topicName,
			ctx.nsqd.getOpts().DataPath,
			ctx.nsqd.getOpts().MaxBytesPerFile,
			int32(minValidMsgLength),
			int32(ctx.nsqd.getOpts().MaxMsgSize)+minValidMsgLength,
			ctx.nsqd.getOpts().SyncEvery,
			ctx.nsqd.getOpts().SyncTimeout,
			ctx.nsqd.getOpts().Logger)
	}
    //最重要goroutine
	t.waitGroup.Wrap(func() { t.messagePump() })
	t.ctx.nsqd.Notify(t)
	return t
}
```

这个NewTopic函数先是实例化一个Topic实例，最后生成了一个goroutine来处理这个topic的消息，这个t.messagePump协程中执行了消息分发，代码如下:
```golang
func (t *Topic) messagePump() {
	var msg *Message
	var buf []byte
	var err error
	var chans []*Channel
	var memoryMsgChan chan *Message
	var backendChan chan []byte

	t.RLock()
    //获取这个topic下的所有channel
	for _, c := range t.channelMap {
		chans = append(chans, c)
	}
	t.RUnlock()

	if len(chans) > 0 {
		memoryMsgChan = t.memoryMsgChan
		backendChan = t.backend.ReadChan()
	}

	for {
		select {
        /* 获取消息 */
		case msg = <-memoryMsgChan:
		case buf = <-backendChan:
			msg, err = decodeMessage(buf)
			if err != nil {
				t.ctx.nsqd.logf("ERROR: failed to decode message - %s", err)
				continue
			}
            /* 省略一些特殊情况处理 */
		for i, channel := range chans {
			chanMsg := msg
			/*
            * 复制每个消息，并且分发给每个channel
            */
			if i > 0 {
				chanMsg = NewMessage(msg.ID, msg.Body)
				chanMsg.Timestamp = msg.Timestamp
				chanMsg.deferred = msg.deferred
			}
			if chanMsg.deferred != 0 {
				channel.PutMessageDeferred(chanMsg, chanMsg.deferred)
				continue
			}
			err := channel.PutMessage(chanMsg)
			if err != nil {
				t.ctx.nsqd.logf(
					"TOPIC(%s) ERROR: failed to put msg(%s) to channel(%s) - %s",
					t.name, msg.ID, channel.name, err)
			}
		}
	}

exit:
	t.ctx.nsqd.logf("TOPIC(%s): closing ... messagePump", t.name)
}
```

当创建出一个Topic之后，这个Topic的messagePump协程也随之创建，并且处于一个循环中，等待消息的到达。消息来源有两种，第一种就是之前在Topic.put函数中往t.memoryMsgChan写入的消息。还有一种是读取磁盘中消息。ok，当在messagePump函数中读取到消息之后，接着把消息分发到附属这个Topic的所有channel。

到这里，我们可以做个小结，
> 当producer连上nsqd之后，向nsqd发送PUB命令投递消息；接着nsqd根据命令topic的名称在已经存在的topics中查找，如果查找到，则返回已存在的topic，如果不存在，则新建一个topic；然后把消息封装成Message写入Topic.memoryMsgChan；最后由Ｔopic.messagePump将消息分发给附属的channel。

之前为消息如何投递到Ｔopic，后面将要介绍channel是如何把消息投递给client。

# 消费者如何接收消息

----

这小节主要讲讲channel如何将消息发送给client，紧接着上述messagePump函数，将topic消息发送给channel的函数channel.PutMessage(chanMsg)，代码如下:
```golang
func (c *Channel) PutMessage(m *Message) error {
	c.RLock()
	defer c.RUnlock()
	if c.Exiting() {
		return errors.New("exiting")
	}
	err := c.put(m)
	if err != nil {
		return err
	}
	atomic.AddUint64(&c.messageCount, 1)
	return nil
}
/* ------------------------------------------------------------------- */
func (c *Channel) put(m *Message) error {
	select {
	case c.memoryMsgChan <- m:
	default:
		b := bufferPoolGet()
		err := writeMessageToBackend(b, m, c.backend)
		bufferPoolPut(b)
		c.ctx.nsqd.SetHealth(err)
		if err != nil {
			c.ctx.nsqd.logf("CHANNEL(%s) ERROR: failed to write message to backend - %s",
				c.name, err)
			return err
		}
	}
	return nil
}
```

channel的这两个函数和topic的一样，都是把消息优先发送给内存channel，当channel满了之后，把后续的消息append到磁盘文件。那么nsqd中在哪接收c.memoryMsgChan了？原先我以为和Topic一样，channel也会存在一个messagePump协程，用于接收c.memoryMsgChan的消息，而且早期的版本也是这么做的。但是不知道哪个版本之后，channel.messagePump取消了。所以最终是在哪接收c.memoryMsgChan的消息了？那要从consumer连上nsqd后说起。

consumer和producer连接nsqd的代码逻辑是一样的，最终consumer也是处于protocolV2.IOLoop函数中，
```golang
func (p *protocolV2) IOLoop(conn net.Conn) error {
	var err error
	var line []byte
	var zeroTime time.Time

	clientID := atomic.AddInt64(&p.ctx.nsqd.clientIDSequence, 1)
	client := newClientV2(clientID, conn, p.ctx)

	messagePumpStartedChan := make(chan bool)
    /* MessagePump协程是主要任务就是channel把消息投递给client */
	go p.messagePump(client, messagePumpStartedChan)
	<-messagePumpStartedChan

    /* 下面是consumer和nsqd交互的代码部分 */
	for {
		if client.HeartbeatInterval > 0 {
			client.SetReadDeadline(time.Now().Add(client.HeartbeatInterval * 2))
		} else {
			client.SetReadDeadline(zeroTime)
		}

		line, err = client.Reader.ReadSlice('\n')

		// trim the '\n'
		line = line[:len(line)-1]
		// optionally trim the '\r'
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		params := bytes.Split(line, separatorBytes)
		var response []byte
		response, err = p.Exec(client, params)
		if response != nil {
			err = p.Send(client, frameTypeResponse, response)
        }
	}

	p.ctx.nsqd.logf("PROTOCOL(V2): [%s] exiting ioloop", client)
	conn.Close()
	close(client.ExitChan)
	if client.Channel != nil {
		client.Channel.RemoveClient(client.ID)
	}

	return err
}
```

其实之前producer也是有开启go p.messagePump(client, messagePumpStartedChan)协程，但是使用的不多，主要是consumer使用，因此在producer中就把代码删了。下面来看下这个协程:
```golang
func (p *protocolV2) messagePump(client *clientV2, startedChan chan bool) {
        memoryMsgChan = subChannel.memoryMsgChan
        backendMsgChan = subChannel.backend.ReadChan()
        flusherChan = outputBufferTicker.C

		select {
		/* ....省略.... */
		case b := <-backendMsgChan:
			if sampleRate > 0 && rand.Int31n(100) > sampleRate {
				continue
			}

			msg, err := decodeMessage(b)
			if err != nil {
				p.ctx.nsqd.logf("ERROR: failed to decode message - %s", err)
				continue
			}
			msg.Attempts++

            /* 每次给client发送消息时，先把消息放到InFlightQueue */
			subChannel.StartInFlightTimeout(msg, client.ID, msgTimeout)
            /* 增加给该client发送消息的数量 */
			client.SendingMessage()
            /* 真正发送消息的函数 */
			err = p.SendMessage(client, msg, &buf)
			if err != nil {
				goto exit
			}
			flushed = false
		case msg := <-memoryMsgChan:
			if sampleRate > 0 && rand.Int31n(100) > sampleRate {
				continue
			}
			msg.Attempts++

			subChannel.StartInFlightTimeout(msg, client.ID, msgTimeout)
			client.SendingMessage()
			err = p.SendMessage(client, msg, &buf)
			if err != nil {
				goto exit
			}
			flushed = false
		case <-client.ExitChan:
			goto exit
		}
	}
```
从代码可以看出，优先从磁盘获取消息发送给客户端，磁盘没消息，才发送内存channel中的消息。我的理解是这样的
> 如果优先发送内存channel的消息，那么假设在某个时段，产生了大量消息，那么channel中在这个时段都是满的，则磁盘的消息被发送的时机会被延迟到这个时段结束，而如果这个时段很长，消息就会被延迟很久才能发送。而如果是优先发送磁盘，那么在channel满了之后，后续达到的消息都能被优先发送给客户端。当然可能导致channel内部的消息被延迟发送，所以这也是一种折中。

为了保证消息的准确被处理，NSQ做了很多努力
1. 对于每给client发送一个消息，都会先把消息放到InFlightQueue，表示正处于发送的消息而且还没有收到确认。当consumer收到消息时，将回复给nsqd一个FIN命令＋message\_id，表示该消息已经被处理，这时nsqd会将该message\_id从InFlightQueue中删除。
2. 如果客户端处理消息错误，则返回给nsqd一个REQ命令+message\_id+timeout，这时nsqd则把消息放入DeferredQueue队列，等待超时再一次的发送。
3. 如果客户端突然断线，则nsqd将不会收到client的回复，消息还是停留在InFlightQueue中。

还记得之前有提到过，nsqd在Main函数中还单独开启一个goroutine，用于不断处理InFlightQueue和DeferredQueue中的消息，因此在上述两个队列的消息都是有机会发送给client，也就保证消息的正确投递。

这里还需要解释的就是如果一个channel对应多个client，那么channel会随机选择一个client投递消息。这个在代码中不容易看出来，而是利用了go channel的一个很重要的特性
>当往某个channel写入一个消息时，如果有多个goroutine在监听channel的读端，那么只有一个goroutine能接收到该消息。

因此如果有多个client订阅同一个channel，那么这些client监听的是同一个channel.memoryMsgChan，当往某个channel写入消息时，则只有一个client能收到消息。

至于给client发送消息的具体细节，这里就不再详细介绍，代码很简单。

# 总结

-----

这篇主要介绍了nsqd是如何接收producer的消息以及如何把消息投递给client。NSQ消息队列架构比较简单，分布式架构也很好理解，结合golang的goroutine和channel实现了处理消息的高效以及代码的优雅，还有http模块中间件的封装，源码很值得阅读。

