const ArenaAllocator = @This(); // 把当前文件当作结构体ArenaAllocator

// Zig的文件级（顶层）声明与书写顺序无关
// 结构体有两个字段
child_allocator: Allocator, // :表示是什么类型
state: State,

// 定义结构体类型，起名为State
pub const State = struct { // pub影响跨文件的访问，const声明一个编译期常量
    used_list: ?*Node = null, // *Node 指向单个Node元素的指针，?表示可能为空null
    free_list: ?*Node = null, // =null表示字段默认值为null

    // 定义一个编译期常量
    pub const init: State = .{ // 默认不继承pub属性，需要自己加
        .used_list = null,
        .free_list = null,
    };

    pub fn promote(state: State, child_allocator: Allocator) ArenaAllocator {
        return .{
            .child_allocator = child_allocator,
            .state = state,
        };
    }
};

pub fn allocator(arena: *ArenaAllocator) Allocator {
    // .{} anonymous struct literal（匿名结构体字面量）
    // 在 .{} 里用 .字段名 = 值 初始化字段
    return .{
        // *anyopaque类型擦除指针，类似C语言的void*
        .ptr = arena,
        // &取地址，&.{ ... } 得到一个指向匿名结构体的指针
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

const Node = struct {
    size: Size,
    end_index: usize,
    next: ?*Node,
    // packed位精确布局，从最低有效位LSB开始依次排列
    const Size = packed struct(usize) { // usize是“背靠整数”，可以@bitCast互转
        resizing: bool, // 占一个bit
        // @bitSizeOf求位长，@Int构造一个n位的无符号整数类型
        _: @Int(.unsigned, @bitSizeOf(usize) - 1) = 0, // _是匿名填充字段

        fn fromInt(int: usize) Size { // 传入int的需要是2的倍数
            // 至少要覆盖Node头部大小
            assert(int >= @sizeOf(Node)); // @sizeOf求类型在内存中占用的字节数
            // @bitCast位模式重新解释
            const size: Size = @bitCast(int); // 局部const不要求值编译器确定，只要求绑定不可变
            assert(!size.resizing); // 不可以伸缩
            return size;
        }

        fn toInt(size: Size) usize {
            var int = size;
            int.resizing = false; // 可能会正在resize，所以要清掉这个位
            return @bitCast(int);
        }

        comptime { // 编译器自检
            // assert(左==右)要求两边逐位相等，@as用于类型转换，@bitCast会类型推断
            assert(Size{ .resizing = true } == @as(Size, @bitCast(@as(usize, 1))));
        }
    };

    // []u8切片 指针+长度
    fn loadBuf(node: *Node) []u8 {
        // @atomicLoad(类型, 指针, 内存序)
        const size = @atomicLoad(Size, &node.size, .monotonic);
        // [*]u8多元素指针类型，数量未知。[a..b]从a到b（不含b），转换为切片[]u8
        // slice[start..] 返回子切片，起点后移 start，长度 = 原长度 - start。
        return @as([*]u8, @ptrCast(node))[0..size.toInt()][@sizeOf(Node)..];
    }

    fn beginResize(node: *Node) ?[]u8 {
        // @atomicRmw(T, ptr, op, operand, ordering)
        // 原子执行ptr.* = ptr.* op operand并返回旧值
        // acquire的精确语义
        // 我这次 acquire 读之后，我读的所有普通内存，都不会被重排到这次读之前；
        // 并且，如果这次读读到了某个 release 写，那么那个 release 写之前写的所有普通内存，我都能看到。
        // release的精确语义
        // 我这次 release 写之前，我写的所有普通内存，都已完成；之后 acquire 读到这个原子值的线程，能看到这些普通内存写。
        const size = @atomicRmw(Size, &node.size, .Or, .{ .resizing = true }, .acquire); // 与endResize的release同步
        // 旧值为true说明别人已锁定，锁失败，返回
        if (size.resizing) return null;
        return @as([*]u8, @ptrCast(node))[0..size.toInt()];
    }

    fn endResize(node: *Node, size: usize, prev_size: usize) void {
        assert(size >= prev_size); // 节点不得收缩
        // unordered最宽松的原子序，只保证原子读写，不保证对同一地址的多次写入在所有线程看来有一个一致的先后顺序
        // 比较完就抛弃，不反馈到控制流中，所以用.unordered，一般用.monotonic
        assert(@atomicLoad(Size, &node.size, .unordered).toInt() == prev_size); // 一致性校验
        return @atomicStore(Size, &node.size, .fromInt(size), .release); // 与beginResize的require同步
    }

    // 非线程安全
    fn allocatedSliceUnsafe(node: *Node) []u8 {
        return @as([*]u8, @ptrCast(node))[0..node.size.toInt()];
    }
};

fn loadFirstNode(arena: *ArenaAllocator) ?*Node {
    return @atomicLoad(?*Node, &arena.state.used_list, .acquire); // 与成功的tryPushNode中的release同步
}

// 带标签的联合体，二选一类型，要么是success不带数据，要么是failure带一个?*Node数据。
// 用enum做标签，运行时能知道当前是哪一种。
const PushResult = union(enum) {
    success,
    failure: ?*Node,
};

fn tryPushNode(arena: *ArenaAllocator, node: *Node) PushResult {
    // 如果 node.next == node，说明链表已经形成自环，后续访问会死循环；这是严重 bug，尽早 panic。
    assert(node != node.next);
    if (@cmpxchgStrong( // 用 strong，因为重试意味着丢弃一个合适的节点 → 代价很高。
        ?*Node,
        &arena.state.used_list,
        node.next,
        node,
        .release, // 成功写入，与失败路径或 loadFirstNode 中的 acquire 同步。
        .acquire, // 需读出旧值，与成功路径的release同步
    )) |old_node| {
        return .{ .failure = old_node };
    } else {
        return .success;
    }
}

// 把free_list偷完
fn stealFreeList(arena: *ArenaAllocator) ?*Node {
    // 这里用不着 acq_rel，因为交换进去的总是 null；既然没有把任何节点“发布”出去，也就不需要 release 语义。
    // 原子地把 arena.state.free_list 换成 null，并返回换之前的值（原来整个 free 链表的头）。
    return @atomicRmw(?*Node, &arena.state.free_list, .Xchg, null, .acquire); // 与 pushFreeList 中的 release 同步。
}

// 无锁地把一段链表 [first, last] 推入 arena.state.free_list 头部的函数
// 成功后free_list ──▶ first ──▶ ... ──▶ last ──▶ (原来的 free_list 头或 null)
fn pushFreeList(arena: *ArenaAllocator, first: *Node, last: *Node) void {
    assert(first != last.next); // 段尾的next不能指回环头（防止段内成环）
    assert(first != first.next); // first不能自环
    assert(last != last.next); // last不能自环
    // @cmpxchgWeak(T, ptr, expected, new, success_order, fail_order) ?T
    // 成功（*ptr == expected）：写入 new，返回 null
    // 失败（*ptr != expected）：不写，返回当前的旧值（包装成 optional）
    // Weak 表示允许伪失败（spurious failure）：即使值相等也可能返回失败，新值不会写入。
    // 推入成功后必有last.next == 推入前的free_list头
    while (@cmpxchgWeak(
        ?*Node,
        &arena.state.free_list,
        last.next,
        first,
        .release, // 与stealFreeList的acquire同步。写入new，写操作，需要release（发布）
        .monotonic, // 我们从来不会访问old_free_list的任何字段，我们只关心指针
        // 内存序。写写写release，acquire读读读。
    )) |old_free_list| { // 返回旧值
        // last是指针，自动解引用
        last.next = old_free_list;
    }
}

fn alignedIndex(buf_ptr: [*]u8, end_index: usize, alignment: Alignment) usize {
    // +% -% wrapping算术，取模环绕
    // .forward返回向上对齐后的偏移量
    // 返回对齐后的相对偏移
    return alignment.forward(@intFromPtr(buf_ptr) +% end_index) -% @intFromPtr(buf_ptr);
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    // @alignCast对齐信息向上转换，比如类型对齐从1变成8
    // 依赖“结果类型推断”（result type inference）
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = ret_addr; // 不使用返回地址信息

    assert(n > 0); // 确认分配的内存大小要大于0

    var cur_first_node = arena.loadFirstNode(); // 已使用链表的第一个

    var cur_new_node: ?*Node = null;

    // defer 后面跟一个表达式，在离开当前作用域时执行。执行顺序：后进先出LIFO
    // if()||{} optional捕获语法，只有非null时才进入语句块，node为解包后的payload
    defer if (cur_new_node) |node| {
        node.next = null; // 针对空free_list优化
        arena.pushFreeList(node, node); // first和last都是node
    };

    // 带标签循环
    retry: while (true) {
        // 多重赋值与解构，等号右边first_node: {}是一个带标签的块表达式
        const first_node: ?*Node, const prev_size: usize = first_node: {
            // orelse optional解包，如果cur_first_node是null，表达式的值等于右边
            const node = cur_first_node orelse break :first_node .{ null, 0 };
            const buf = node.loadBuf(); // 返回实际的缓冲区地址

            // 为了避免在热路径上使用CAS循环，我们原子地把end_index增加一个足够大的量，确保预留的内存里一定能满足对齐要求。
            // 为了回收因此可能浪费的空间，我们随后用一次 cmpxchg 尝试把“多预留的部分”减回去；这次操作允许失败。

            // toByteUnits返回对齐的字节数。为了能对齐到 alignment 并放下 n 字节，最坏情况下需要预留多少字节。
            const alignable = n + alignment.toByteUnits() - 1;
            // 原子地增加 end_index 来“占用”一段内存。
            // 用 .acquire 语义保证：如果别的线程之前通过 free/缩小 resize 释放过这段内存（那些操作用 .release），那么本线程在拿到新的 end_index 之后，一定能看到那些线程在释放前对这段内存做过的写入。
            // 用 acquire 语义，同步任何可能已被其他线程释放的内存。Rmw返回旧值
            const end_index = @atomicRmw(usize, &node.end_index, .Add, alignable, .acquire);
            // 获取原end_index对齐后的和缓冲区基址的相对偏移。存放数据的实际起址（因为要对齐）
            const aligned_index = alignedIndex(buf.ptr, end_index, alignment);
            // end_index + alignable 我实际预留的位置，end_index已被更新为这个值。最坏情况下预留的终点
            // aligned_index + n     数据实际需要到哪个位置，从对齐点放n个字节后的末尾位置。对齐后放完数据的终点
            assert(end_index + alignable >= aligned_index + n); // 实际分配空间的末尾 >= 实际占用空间的末尾
            if (end_index + alignable != aligned_index + n) {
                // 把之前多预留的对齐填充padding还回去，让end_index从“最坏预留终点”退回“实际数据终点”。
                _ = @cmpxchgStrong( // 不要求成功，只是优化
                    usize,
                    &node.end_index,
                    end_index + alignable,
                    aligned_index + n,
                    .monotonic, // 不需要用 release 语义发布对齐填充；因为没有任何线程在访问这块 padding。
                    .monotonic,
                );
            }

            // node.end_index不一定小于buf_len，以实际占用长度判断
            // 这个节点放不下这次分配，退出。返回当前节点和当前节点对应缓冲区总长度
            if (aligned_index + n > buf.len) break :first_node .{ node, buf.len };
            return buf[aligned_index..][0..n].ptr; // 函数返回
        };

        resize: {
            const node = first_node orelse break :resize; // 为空则退出resize块
            // 尝试独占这个节点并开始 resize；如果节点已经被别的线程占用（正在 resize），就跳出 resize: 块，放弃在当前节点上扩容，改走后面的路径。
            const allocated_slice = node.beginResize() orelse break :resize;
            var size = allocated_slice.len; // 记录当前节点大小size
            defer node.endResize(size, allocated_slice.len); // 通过 defer 调用 endResize 释放 resizing 锁，并把（可能已经变大的）size 写回节点。

            const buf = allocated_slice[@sizeOf(Node)..]; // 数据缓冲区
            // 读到旧值不会导致错误，只会导致这次 resize 作废、走其他路径。下面的@cmpxchgStrong会检查的
            const end_index = @atomicLoad(usize, &node.end_index, .monotonic); // end_index字段值
            const aligned_index = alignedIndex(buf.ptr, end_index, alignment); // end_index对齐后的相对偏移
            // mem.alignForward(usize, 值, 对齐数), 把 值 向上对齐到 对齐数 的整数倍
            const new_size = mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2); // +n了

            if (new_size <= allocated_slice.len) {
                // 有一个 resize 或 free 调用插了进来，而我们需要保证 size 只会增加；重试！
                // 进入 resize: 块的前提是“热路径发现当前节点放不下”。
                // 但进来后重新读 end_index 算出的 new_size 如果 <= allocated_slice.len，
                // 说明基于最新状态当前节点其实放得下（或不需要再扩），不需要 resize，应该回到 retry 循环重新走热路径。
                continue :retry;
            }

            // 调用底层分配器，尝试把 allocated_slice 这块内存原地调整到 new_size 大小；成功返回 true
            // @returnAddress() 是 Zig 的一个内建函数（builtin function），它的核心作用是获取当前函数返回后，调用者将要执行的下一条指令的地址。
            // 按照Node的方式对齐
            if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
                size = new_size; // 调整完毕，可以安全更新size
                // 这里用 strong，是因为如果发生伪失败，可能会导致这个节点的空间利用率变差。
                if (null == @cmpxchgStrong( // strong值相等时一定成功
                    usize,
                    &node.end_index,
                    end_index,
                    aligned_index + n,
                    .acquire, // 以 acquire 内存序，同步任何可能已被其他线程释放的内存。
                    .monotonic,
                )) { // 成功的话才会返回null进入这个语句块
                    // 从扩容后的节点内存起始地址开始，取前 new_size 字节，再去掉开头的 Node 头部，得到数据区的切片。
                    const new_buf = allocated_slice.ptr[0..new_size][@sizeOf(Node)..];
                    return new_buf[aligned_index..][0..n].ptr; // 函数返回
                }
            }
        }

        // 我们需要一个新节点！首先，我们在 free_list 里找一个足够大的；
        // 如果在那儿找不到，就退回到用 child_allocator 分配一个新节点（如果我们还没这么做的话！）。
        from_free_list: {
            // 我们直接把整条 free_list “偷走”，这样操作期间就没有别的线程来插手。
            // 这种做法比较务实；free_list 本身使用频率不高，所以即便在负载下性能也还可以。
            // 而且它能避开 ABA 问题——用一次原子交换把整条链表偷走，不会留下任何可能过期的 next 指针。
            const free_list = arena.stealFreeList() orelse break :from_free_list; // 为空退出block，保证free_list不为空

            const first_free: *Node, const last_free: *Node, const node: *Node, const prev: ?*Node = find: {
                var best_fit_prev: ?*Node = null;
                var best_fit: ?*Node = null;
                // 把 best_fit_diff 初始化为 usize 能表示的最大值，表示“目前还没找到任何候选节点”；
                var best_fit_diff: usize = std.math.maxInt(usize);

                var it_prev: ?*Node = null; // 初始迭代器的前一节点为空
                var it: ?*Node = free_list; // 初始迭代器为free_list
                // 只要it不是null，就解包出node执行循环体，每轮循环结束时，执行:({...})里的继续表达式，把it_prev更新为当前节点，it推进到下一节点
                // 类似 C 的 for (;; 这里)
                while (it) |node| : ({
                    it_prev = node; // 这里会持续更新，直到尾节点，所以不能在diff=0的这个地方退出
                    it = node.next;
                }) {
                    assert(!node.size.resizing); // 节点不应该处于“正在被 resize”的状态
                    // 因为节点已经被 stealFreeList 偷到私有链表，本线程独占，不需要 resizing 标志做排他。
                    // 所以 free_list 里的节点即使被 resize，也不会进入 resizing == true 状态。
                    // 取出节点整个内存切片，跳过开头的 Node 头部，得到数据区切片 buf。
                    const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
                    // 从数据区起点 buf.ptr 开始，算出第一个满足 alignment 对齐的地址相对于 buf.ptr 的偏移量。
                    const aligned_index = alignedIndex(buf.ptr, 0, alignment);

                    // 算这个空闲节点离“放得下 n 字节”还差多少。放得下就是 0；放不下就是差多少字节。
                    // aligned_index + n 在这个节点里放下 n 字节，数据需要到达的偏移。
                    // -|是饱和减法，a>=b返回a-b，a<b返回0
                    const diff = aligned_index + n -| buf.len;
                    // 如果当前节点比之前找到的最佳节点更合适（diff 更小），就把它记为新的最佳，同时记下它的前驱和差距。
                    if (diff < best_fit_diff) {
                        best_fit_prev = it_prev; // 记录快照
                        best_fit = node;
                        best_fit_diff = diff; // 更新差值
                    }
                }
                // 返回头部节点，尾部节点的前驱，最适合节点及其前驱。不为空，可以.?解包
                break :find .{ free_list, it_prev.?, best_fit.?, best_fit_prev };
            };

            const aligned_index, const need_resize = aligned_index: {
                // 提取best_fit节点的数据区
                const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
                // 算出第一个数据的索引位置
                const aligned_index = alignedIndex(buf.ptr, 0, alignment);
                // aligned_index + n > buf.len 数据终点超过节点大小，需要扩容
                break :aligned_index .{ aligned_index, aligned_index + n > buf.len };
            };

            if (need_resize) {
                // 理想情况下，free_list 里的节点我们最终都想用上；因此哪怕没有一个够大，也会拿“差得最少”的那个节点去 resize，尽量把它扩到够用。
                const new_size = mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2); // 算出新大小
                // 扩容node
                if (arena.child_allocator.rawResize(node.allocatedSliceUnsafe(), .of(Node), new_size, @returnAddress())) {
                    node.size = .fromInt(new_size); // 更新size字段
                } else { // 底层分配器扩容失败
                    arena.pushFreeList(first_free, last_free); // 放回
                    break :from_free_list; // 退出当前块，我们没能找到合适的空闲节点。
                }
            }

            // 获取node数据缓冲区
            const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
            const old_next = node.next; // 备份next指针

            node.end_index = aligned_index + n; // 更新空间末尾指针
            node.next = first_node; // 更新next指针，满足tryPushNode条件

            switch (arena.tryPushNode(node)) {
                .success => {
                    // 完成从 free_list 中摘除该节点。
                    // prev是node原本的前驱节点
                    if (prev) |p| p.next = old_next; // 成功摘除，链上

                    // 把偷来的空闲链表中剩下的部分放回 arena.state.free_list。
                    // 处理两种特殊情况，摘除的是头节点/尾节点
                    const new_first_free = if (node == first_free) old_next else first_free;
                    const new_last_free = if (node == last_free) prev else last_free;
                    // 头部结点为空也就没有必要归还了
                    if (new_first_free) |first| {
                        const last = new_last_free.?; // 解包头尾节点，但不需要判尾部是否为空。头不为空则尾不为空
                        arena.pushFreeList(first, last);
                    }

                    // 返回从aligned_index开始的指针，确保对齐
                    return buf[aligned_index..][0..n].ptr;
                },
                .failure => |old_first_node| {
                    // 把空闲链表恢复成我们发现它时的样子
                    node.next = old_next; // 恢复节点，重试
                    arena.pushFreeList(first_free, last_free);

                    cur_first_node = old_first_node; // 因为有新插入的头节点，所以更新cur_first_node
                    continue :retry; // 有一个新的头节点，重试
                },
            }
        }

        const new_node: *Node = new_node: {
            // 解包cur_new_node，进入第二轮循环就有payload了
            if (cur_new_node) |new_node| {
                break :new_node new_node;
            } else {
                // Zig 语言向编译器提供分支预测提示的内置函数。
                // 告诉优化器：这条分支路径在程序运行时“几乎不可能”会被执行到。
                // .cold相比.unlikely语义更强
                @branchHint(.cold);
            }

            const size: Node.Size = size: {
                // 最少需要放入Node头部、对齐填充、n这么多空间
                const min_size = @sizeOf(Node) + alignment.toByteUnits() + n;
                // prev_size原缓冲区的大小，额外16字节余量
                const big_enough_size = prev_size + min_size + 16;
                // 先把 big_enough_size 放大到约 1.5 倍，再向上对齐到 2 的倍数。
                const size = mem.alignForward(usize, big_enough_size + big_enough_size / 2, 2); // 保证是2的倍数
                break :size .fromInt(size); // size需要是2的倍数
            };
            const ptr = arena.child_allocator.rawAlloc(size.toInt(), .of(Node), @returnAddress()) orelse
                return null; // 否则没有办法继续分配了
            const new_node: *Node = @ptrCast(@alignCast(ptr)); // 转成Node指针
            new_node.* = .{ // 给字段赋值
                .size = size,
                .end_index = undefined, // 在下面设置
                .next = undefined, // 在下面设置
            };
            cur_new_node = new_node;
            break :new_node new_node; // 返回并赋值
        };

        // 提取出数据缓冲区，新分配节点，不存在线程争用
        const buf = new_node.allocatedSliceUnsafe()[@sizeOf(Node)..];
        // 找到n字节数据插入起始索引
        const aligned_index = alignedIndex(buf.ptr, 0, alignment);
        // 确保缓冲区能容下Node头部+对齐padding+n字节
        assert(new_node.size.toInt() >= @sizeOf(Node) + aligned_index + n);

        // 更新end_index，数据末尾索引
        new_node.end_index = aligned_index + n;
        // 更新next指针，插入used_list中
        new_node.next = first_node;

        switch (arena.tryPushNode(new_node)) {
            .success => {
                cur_new_node = null; // 置空并返回，因为有defer必须置空
                return buf[aligned_index..][0..n].ptr;
            },
            .failure => |old_first_node| { // 说明used_list的头结点发生变化，需要更新当前信息
                cur_first_node = old_first_node;
                // defer会兜底，分配出的新节点cur_new_node进入used_list或者插入free_list中（只执行一次）
            },
        }
    }
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    assert(memory.len > 0);
    assert(new_len > 0);

    const node = arena.loadFirstNode().?;
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
