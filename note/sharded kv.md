### 关于load re-balancing

lab2和lab3构建了一个具有容错、强一致性的键值对存储系统。在这个系统中，只有leader能够处理客户端的请求，因此leader是系统的性能瓶颈。
在分布式系统中，为了提高系统的整体性能，通常会将请求分配到不同的机器上处理（即利用并行性），从而提高系统的吞吐量。
对于单个raft集群（记为**raft group**，即通过raft共识算法保证系统的一致性的主机集合），只有一个leader，不能有多个leader。
因此我们可以将请求分配给多个**raft group**，每个**raft group**负责一部分的请求，这样一来，系统的整体性能就是多个leader的性能总和。
为了使不同**raft group**负载相当，还需要进行一些额外操作，使每个**raft group**的负载大致平衡，这也就是lab4a目的所在。

一个系统中，会添加新的**raft group**（对应于join），也会移除不需要的**raft group**（对应于`leave`），在这两种操作之后，就需要对**raft group**的负载进行调整。
那么，我们怎么知道哪个请求应该交给哪个**raft group**处理呢？最简单的方式是通过请求的哈希值来判断，就好像map那样。
lab4a使用shard（可以看作一个请求的哈希值）来表示，一个**raft group**所分得的shard越多，对应的负载越大。
在负载均衡的过程中，lab4a提出了两个要求：
1. group 之间的负载一定要是均衡的，即不同group服务shard的数量最多相差一个。
2. 变更负载过程中，转移的shard要尽量少。

这两个要求很好理解，就是让我们做最少的事情，达到最好的效果。现在来说说方案：
给定`Nshard`，有`n`个group，要使这`n`个group的负载均衡，很自然能想到这样的平均分配方案：
avg = Nshard / n`每个group应当分配`avg`个shard， ；剩下`mod = Nshard % n`个shard可以均分给`mod`个group（mod < n)。

#### Join
Join是向系统中添加1个或多个**raft group**。根据系统Join前的**raft group**的数量是否为0可以分为两种情况。
- **Join前的raft group数量为0**：
按照每个group分配`avg`个shard，然后再给`mod`个group分配1个shard即可。
```go
func (sc *ShardCtrler) balanceJoin(groupServers map[int][]string) {
    var totalGroups int
	previousGroups := len(sc.replicaGroups)
	if previousGroups == 0 {
		totalGroups = newGroups
		avg := NShards / totalGroups
		mod := NShards % totalGroups
		i := 0
		for _, gid := range groupIds {
			for j := 0; j < avg; j++ {
				sc.shards[i] = gid
				i++
			}
			if mod > 0 {
				sc.shards[i] = gid
				i++
				mod--
			}
		}
	}
}
```
- **Join前的raft group数量不为0**：
当新加入`m`个group时，就需要从原来的`n`groups中转移一些shard给这些group，以达到负载均衡。再使用上面给的分配方案可以得到`avg = Nshard / (m + n)`
`mod = Nshard % (n + m)`。将`Nshard`全部重新分配可以达到第一个要求，但是达不到第二个要求。因此需要从原来的`n`个group的shard，转移一部分到
新的`m`个group。为了使转移的shard数量最少，优先从含有shard数量最多的group分配出去。

我们可以先对原有的`n`个group所负责shard数量按照从大到小排序（在这里要保证 排序是**deterministic**，即遇到shard数量相同的组时，也要按照一定的顺序排序）。
```go
type ShardGroup struct {
	gid    int
	shards []int
}

type ByShardCount []ShardGroup

// for sorting by shard count.
func (a ByShardCount) Len() int      { return len(a) }
func (a ByShardCount) Swap(i, j int) { a[i], a[j] = a[j], a[i] }
func (a ByShardCount) Less(i, j int) bool {
	// shard re-balancing needs to be deterministic.
	return len(a[i].shards) < len(a[j].shards) || (len(a[i].shards) == len(a[j].shards) && a[i].gid < a[j].gid)
}

// shardGroups Return the shards in charge of each group which is sorted by number of shards
// If different groups has the same number of shards, then sort by gid
func (sc *ShardCtrler) shardGroups() []ShardGroup {
	shardsMap := make(map[int][]int)
	for gid := range sc.replicaGroups {
		shardsMap[gid] = make([]int, 0)
	}
	for shard, gid := range sc.shards {
		shardsForG := shardsMap[gid]
		shardsMap[gid] = append(shardsForG, shard)
	}
	var shardGroups ByShardCount
	for gid, shards := range shardsMap {
		shardGroups = append(shardGroups, ShardGroup{gid: gid, shards: shards})
	}
	sort.Sort(shardGroups)
	return shardGroups
}
```

设`shards[gid]`表示第i组所负责的shards数组，按照从大到小的顺序遍历，可知，每个group应当为新group分配`len(shards[gid]) - avg`个shard。
因此在给`n+m`个group分别负责`avg`个shard后，还有`mod`个shard未分配。不同group之间的shards最多相差一个，
因此这`mod`个shard要平均分给`mod`个group，因此前`mod`个group可以少分配一个shard。因此有以下代码：
```go
func (sc *ShardCtrler) balanceJoin(groupServers map[int][]string) {
	var totalGroups int
	previousGroups := len(sc.replicaGroups)
	if previousGroups == 0 {
		//...
	} else if previousGroups < NShards {
		shardGroups := sc.shardGroups()
		totalGroups = newGroups + previousGroups
		avg := NShards / totalGroups
		mod := NShards % totalGroups
		var shardsToDistribute []int
		for i := len(shardGroups) - 1; i >= 0; i-- {
			shards := shardGroups[i].shards
			shardCount := len(shards)
			// indivisible ?
			if shardCount <= 1 {
				break
			}
			var distribute int
			if avg < 1 {
				distribute = shardCount - 1
			} else {
				distribute = shardCount - avg
				if mod > 0 {
					distribute--
					mod--
				}
			}
			for j := 0; j < distribute; j++ {
				shardsToDistribute = append(shardsToDistribute, shards[j])
			}
		}
		avg = len(shardsToDistribute) / newGroups
		mod = len(shardsToDistribute) % newGroups
		i := 0
		for _, gid := range groupIds {
			for j := 0; j < avg; j++ {
				sc.shards[shardsToDistribute[i]] = gid
				i++
			}
			if mod > 0 {
				sc.shards[shardsToDistribute[i]] = gid
				i++
				mod--
			}
		}
	}
	//...
}
```

#### Leave
和`Join`操作类似，也可以根据`Leave`操作后的**raft group**的数量是否为0分为两种情况：
- **Leave操作后的raft group数量为0**：
由于没有了**raft group**，因此所有的shard指向都是空，因此可以简单地将shard的**raft group**设置为0：
```go
func (sc *ShardCtrler) balanceLeave(groupIds []int) {
	// keep only valid group ids
	var leaveIds []int
	for _, gid := range groupIds {
		if _, exist := sc.replicaGroups[gid]; exist {
			leaveIds = append(leaveIds, gid)
		}
	}
	groupsToLeave := len(leaveIds)
	if groupsToLeave == 0 {
		return
	}
	groupsAfterLeave := len(sc.replicaGroups) - groupsToLeave
	if groupsAfterLeave == 0 {
		// no groups, then group 0 serve all shards
		for i := range sc.shards {
			sc.shards[i] = 0
		}
	} else {
		//...
    }
}
```
- **Leave操作后的raft group数量不为0**：
假设移除`m`个**raft group**，则这`m`个**raft group**所负责的shard要分配给剩下的`n`个**raft group**。这些shard可以看作是`Join`操作中要分配出去的shard，
而剩下的`n`个**raft group**可以看作是`Join`操作添加的**raft group**。因此可以和`Join`操作一样处理这些shard的分配。
将`Join`和`Leave`所要用到的相同代码抽取为一个方法：
```go
// distributeShards distribute  the given shards to the specified groups evenly
func (sc *ShardCtrler) distributeShards(shardsToDistribute []int, groupsToDistribute []int) {
	groups := len(groupsToDistribute)
	avg := len(shardsToDistribute) / groups
	mod := len(shardsToDistribute) % groups
	i := 0
	for _, gid := range groupsToDistribute {
		for j := 0; j < avg; j++ {
			sc.shards[shardsToDistribute[i]] = gid
			i++
		}
		if mod > 0 {
			sc.shards[shardsToDistribute[i]] = gid
			i++
			mod--
		}
	}
}
```
因此，`balanceLeave`方法最终是这个样子：
```go
func (sc *ShardCtrler) balanceLeave(groupIds []int) {
	var leaveIds []int
	for _, gid := range groupIds {
		if _, exist := sc.replicaGroups[gid]; exist {
			leaveIds = append(leaveIds, gid)
		}
	}
	groupsToLeave := len(leaveIds)
	if groupsToLeave == 0 {
		return
	}
	groupsAfterLeave := len(sc.replicaGroups) - groupsToLeave
	if groupsAfterLeave == 0 {
		// no groups, then group 0 serve all shards
		for i := range sc.shards {
			sc.shards[i] = 0
		}
	} else {
		shardGroups := sc.shardGroups()
		leaveIdMap := make(map[int]byte)
		for _, gid := range leaveIds {
			leaveIdMap[gid] = 1
		}
		var shardsToDistribute []int
		var groupsToTransfer []int
		for _, shardGroup := range shardGroups {
			gid := shardGroup.gid
			if _, inLeaveGroup := leaveIdMap[gid]; inLeaveGroup {
				shardsToDistribute = append(shardsToDistribute, shardGroup.shards...)
			} else {
				groupsToTransfer = append(groupsToTransfer, gid)
			}
		}
		sc.distributeShards(shardsToDistribute, groupsToTransfer)
	}
	// ...
}
```