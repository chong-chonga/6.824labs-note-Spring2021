## 谈谈raft该如何将log和snapshot发送给上层service
读完raft论文后，对整个算法有了比较清晰的认识；但是论文对具体的实现没有讲得很仔细。
因此在实现Raft过程中，出现的很多问题都是策略问题，而不是机制问题。正是因为有很多可选的实现方案，所以非常让人纠结该选何种实现方式。
举个最简单的例子：大家都知道到达罗马（机制），坐车还是坐飞机，沿途风景如何，乘坐感受如何等等（策略本身的影响）非常让人纠结。
下面则是我在实现Raft过程中的一些思考。

### raft应该怎样向上层的service发送log?
阅读raft论文可知，raft 需要将 committed log 通过 channel 发送给上层的 service。
因此，raft发送log就是在更新`commitIndex`后 ，而只有在以下两种情况中才会更新`commitIndex`：
- follower 收到来自 leader `AppendEntries` RPC调用更新 `commitIndex` 时
- leader 通过对 follower 发起`AppendEntries`或`InstallSnapshot`RPC后，自身更新 `commitIndex` 时

因此有两种方案有发送log：
1. **嵌入式**：将 发送 log 的代码插入到上述两种情况中。 好处是可以及时地将 log 发送给 service，且不需要轮询，节省性能（类似于事件驱动、中断）。
坏处就是阻塞，当前 go routine 需要等待所有 log 发送完成后才能继续执行，延长了rpc执行时间。
2. **独立式**： 将 发送 log 的代码作为一个单独的 go routine，通过轮询的方式来判断是否要发送 log。 好处是代码逻辑独立，降低了耦合，且不容易引发死锁。
坏处就是需要轮询，降低了性能，轮询的间隔时间既不能太大，也不能太小。但是这种情况可以改为使用**条件变量**（go语言中的`sync.Cond`）进行优化。
因此`applyLog`方法可能长这样：
```go
    // raft 初始化时，加入如下字段并初始化
    rf.cond := sync.NewCond(&rf.mu)
    // ...
	for {
        rf.cond.L.Lock()
        for rf.lastApplied >= rf.commitIndex {
            rf.cond.Wait()
			if rf.killed() {
                rf.applyCond.L.Unlock()
                return
            }
        }
		
        // ...
		rf.cond.L.Unlock()
    }
	
	// tester 会调用 kill，因此需要通知其取消Wait()
	func (rf *Raft) Kill() {
        atomic.StoreInt32(&rf.dead, 1)
        rf.applyCond.Signal()
	}
```

我选择的是第二种方案，即使用单独的 go routine 来发送 log，因为修改很方便。

#### 其他优化
考虑到原方案使用的阻塞式的`channel`，raft发送server需要等待service接收后，才能继续后面的处理。因此可以采用缓冲式的channel来提高raft处理的速度。

#### lab之外的思考：向channel一次发送1个log还是多个log？
不管是选用上述哪一种方案，都是在持有锁的情况下，才会发送log，而持有锁的时间与处理log的时间成正比，因此还需要考虑一次发送的 log 数量。
以第二种方案举例，有三种实现方式：
1. 每次轮询时，至多发送1个log。这样做的好处是单次处理时间较短，持有锁的时间也比较短；坏处就是处理log比较慢，而如果要加快速度，则轮询间隔要更小，那么抢锁次数就会增多，加大了抢锁开销，
2. 每次轮询时，尽量发送更多log。好处是一次持有锁的时间可以完成多个log，处理log比较快；坏处就是，其他 go routine 等待锁的时间与处理log时间成正比。
3. 6.824提供的每次轮询时，每次向channel发送log数组，而不是单个log。好处是，向channel发送一次即可处理多个log。

### 为什么需要CondInstallSnapshot？
你可能好奇过raft为什么处理snapshot要靠依靠`CondInstallSnapshot`，你可能去问过搜索引擎，很多人告诉你原因是确保service和raft安装snapshot的原子性。
这个问题其实就是：发送log/snapshot时该不该持有全局锁。很多文章说的没错，持有锁时，能够保证发送log/snapshot是串行的；但会造成死锁；
不持有锁，则发送log和snapshot是并发的，所以需要`CondInstallSnapshot`避免service收到过时的snapshot即可。
前半句是对的，后半句不对。只是简单地不持有锁，然后靠着`CondInstallSnapshot`就能实现service和raft安装snapshot的原子性吗？答案是，并不能。

现在来仔细思考一下这两种情况。
#### 发送log/snapshot时持有锁
已经知晓死锁的，可以跳过本部分

假如发送log的go routine全程是持有锁的，那么发送snapshot和发送log是串行的，service就无需过滤过时的log了。为了让raft能及时的释放锁，
service应当持续地接收channel中的消息，也就是说，service接收channel的routine，不应当调用raft并等待调用完成。和网上的一些解答说的一样，service一旦
调用raft的`Snapshot`或`CondInstallSnapshot`就会引发死锁。因此有一个解决办法：开启另一个go routine去调用raft。这样service就持续地接收channel的log。
但是这违背了一开始的设计目标，因为我们就是想先持久化snapshot后再去处理log。

再看课程所给的测试代码：
```go
	for m := range applyCh {
		err_msg := ""
		if m.SnapshotValid {
			if rf.CondInstallSnapshot(m.SnapshotTerm, m.SnapshotIndex, m.Snapshot) {
				//..
			}
		} else if m.CommandValid {
			if m.CommandIndex != cfg.lastApplied[i]+1 {
				err_msg = fmt.Sprintf("server %v apply out of order, expected index %v, got %v", i, cfg.lastApplied[i]+1, m.CommandIndex)
			}
            // ...
		} else {
			// Ignore other types of ApplyMsg.
		}
		if err_msg != "" {
			log.Fatalf("apply error: %v", err_msg)
			// ...
		}
	}
```
测试代码是等待`CondInstallSnapshot`完成，再去处理后续的log。因此我们必须在发送log和snapshot时，不持有锁。


#### 发送log/snapshot时不持有锁：
假设发送log的go routine处理顺序：抢锁->获取要发送的log->更新`lastApplied`->释放锁->向channel发送log
`InstallSnapshot`handler处理顺序：抢锁->`lastIncludedIndex of snapshot > lastApplied && lastIncludedIndex of snapshot > rf.lastIncludedIndex`
->如果为真，更新`rf.lastIncludedIndex = lastIncludedIndex of snapshot`->向channel发送snapshot(可以先释放锁再发送)->...

在不持有锁的情况下发送log和snapshot，如果不进行限制的话，则发送是并发的。service接收到snapshot和log的顺序是不确定的，
service可能先接收到snapshot后接收到log，而log是过时的。 然而这个问题并不会影响通过lab3的测试。

假如lab3的service处理log的代码如下：
```go
func (kv *KVServer) startApply() {
	for !kv.killed() {
		msg := <-kv.applyCh
		kv.mu.Lock()
		if msg.CommandValid {
			op := msg.Command.(Op)
            if msg.CommandIndex < kv.commitIndex {
                log.Println(kv.me, "receive out dated log, expected log index", kv.commitIndex+1, "but receive", msg.CommandIndex)
                kv.mu.Unlock()
                continue
            }
			commandType := op.OpType
			requestId := op.RequestId
			if id, exists := kv.requestMap[op.ClientId]; !exists || requestId > id {
				if APPEND == commandType {
					//...
				} else if PUT == commandType {
					//...
				} else if GET == commandType {
					//...
				} else {
					//...
				}
				kv.requestMap[op.ClientId] = requestId
			} else {
				// duplicate request
			}
            kv.commitIndex = msg.CommandIndex
			// ...
		} else if msg.SnapshotValid {
			//...
		}
		kv.mu.Unlock()
	}
}
```
测试结果如下：
![img_1.png](img_1.png)
即使通过了测试，但打印的日志也表明，raft存在上述提到的问题，但由于service将过时的log被当成重复的请求而过滤了，才没有影响测试结果。
如果上层的service没有这种机制，则service会出问题。

#### 如何解决
持有锁能保证串行发送，但又偏离了原来的设计；不持有锁，则raft存在问题。其实，这个问题的存在有一个前提：
**只为Raft使用一把大锁**。仔细思考就会发现：**发送log、snapshot和处理其他RPC调用其实并不冲突**，不需要锁。实际开发中，我们也往往会使用更细粒度的锁。
既然我们无法使用大锁去控制串行化，也无法将snapshot和log交给单个go routine去发送，那么我们换个思路，使用一把小锁去控制channel发送。
只有小锁还不够，还需要保证这个锁是**公平锁**才行，这样就能控制发送log/snapshot的顺序了。我的思路是： 发送log/snapshot的go routine先抢到全局锁，然后会得到一个`order`，
并递增`order`，随后释放锁。在发送log/snapshot前，会先抢小锁（这里我用的是**条件变量-sync.Cond**，判断`currentOrder`与`order` 是否一致），如果一致
则发送log/snapshot，并递增`currentOrder`；否则就等待，直到被唤醒。

类似于以下伪代码：
```go

currentOrder := 1
nextOrder := 1
//...
func1 () {
    // 发送log/snapshot的 go routine
    mu.Lock()
    // do something
    order := nextOrder
    nextOrder++
    mu.Unlock()
    
    cond.L.Lock()
    for cuurentOrder != order {
    cond.Wait()
    }
    channle <- message
    currentOrder++
    cond.Broadcast()
    cond.L.Unlock()
}
```
发送log和发送snapshot是互斥的，后送的log/snapshot肯定要比前发送的log/snapshot要新，如此一来，`InstallSnapshot` 向channel发送的snapshot必定是比先前发送的log要新，
且log和snapshot是串行发送的；所以 当service收到snapshot时 可以直接安装snapshot，而不需要调用`CondInstallSnapshot`（直接返回true）即可。
在raft类中添加几个字段，并在初始化时设置这些字段即可：
```go
type Raft struct {
    //...
    sendOrderCond *sync.Cond // condition for sendOrder
    sendOrder     int64      // which order can send log/snapshot to applyCh
    nextOrder     int64      // the next order a go routine will get
    
    applyCond *sync.Cond
    applyCh   chan ApplyMsg // for raft to send committed log and snapshot
    
	//...
}
func Make(...) *Raft {
	//...
	rf.applyCond = sync.NewCond(&rf.mu)
    rf.sendOrder = 0
    rf.nextOrder = 0
    rf.sendOrderCond = sync.NewCond(&sync.Mutex{})
	//...
}
```
最终的`applyLog`方法如下：
```go
// applyLog
// a go routine to send committed logs to applyCh
func (rf *Raft) applyLog() {
	for {
		rf.applyCond.L.Lock()
		for rf.lastApplied >= rf.commitIndex {
			rf.applyCond.Wait()
		}
		startIndex := rf.lastApplied + 1
		endIndex := rf.commitIndex
		count := endIndex - startIndex + 1
		messages := make([]ApplyMsg, count)
		// if lastIncludedIndex is -1, then i = lastApplied + 1
		// otherwise, i = lastApplied + 1 - offset
		i := startIndex - rf.lastIncludedIndex - 1
		commandIndex := startIndex
		logTerm := -1
		for j := 0; j < count; j++ {
			logTerm = rf.log[i].Term
			messages[j] = ApplyMsg{
				CommandValid: true,
				Command:      rf.log[i].Command,
				CommandIndex: commandIndex,
				CommandTerm:  logTerm,
			}
			commandIndex++
			i++
		}
		rf.lastApplied = endIndex
		rf.lastAppliedTerm = logTerm
		order := rf.nextOrder
		rf.nextOrder++
		rf.applyCond.L.Unlock()

		rf.sendOrderCond.L.Lock()
		for rf.sendOrder != order {
			rf.sendOrderCond.Wait()
		}
		for _, message := range messages {
			rf.applyCh <- message
		}
		rf.sendOrder++
		rf.sendOrderCond.Broadcast()
		rf.sendOrderCond.L.Unlock()
	}
}
```

#### 最终结果
使用以下测试脚本（testFull.sh)：
```bash
#!/bin/bash
for i in {1..50} ; do
    go test -race
    cd ../kvraft
    go test -race
    cd ../raft
done
```
将结果导入到`result.txt`得到测试结果
```bash
./testFull.sh > result.txt
```
在测试了几个小时之后，我终止了测试，无一FAIL，且不再出现上述日志，说明该方案可行。





