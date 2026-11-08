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

    assert(n > 0);

    var cur_first_node = arena.loadFirstNode();

    var cur_new_node: ?*Node = null;

    // defer 后面跟一个表达式，在离开当前作用域时执行。执行顺序：后进先出LIFO
    // if()||{} optional捕获语法，只有非null时才进入语句块，node为解包后的payload
    defer if (cur_new_node) |node| {
        node.next = null;
        arena.pushFreeList(node, node);
    };

    retry: while (true) {
        const first_node: ?*Node, const prev_size: usize = first_node: {
            const node = cur_first_node orelse break :first_node .{ null, 0 };
            const buf = node.loadBuf();

            const alignable = n + alignment.toByteUnits() - 1;
            const end_index = @atomicRmw(usize, &node.end_index, .Add, alignable, .acquire);
            const aligned_index = alignedIndex(buf.ptr, end_index, alignment);
            assert(end_index + alignable >= aligned_index + n);
            if (end_index + alignable != aligned_index + n) {
                _ = @cmpxchgStrong(
                    usize,
                    &node.end_index,
                    end_index + alignable,
                    aligned_index + n,
                    .monotonic,
                    .monotonic,
                );
            }

            if (aligned_index + n > buf.len) break :first_node .{ node, buf.len };
            return buf[aligned_index..][0..n].ptr;
        };

        resize: {
            const node = first_node orelse break :resize;
            const allocated_slice = node.beginResize() orelse break :resize;
            var size = allocated_slice.len;
            defer node.endResize(size, allocated_slice.len);

            const buf = allocated_slice[@sizeOf(Node)..];
            const end_index = @atomicLoad(usize, &node.end_index, .monotonic);
            const aligned_index = alignedIndex(buf.ptr, end_index, alignment);
            const new_size = mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2);

            if (new_size <= allocated_slice.len) {
                continue :retry;
            }

            if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
                size = new_size;
                if (null == @cmpxchgStrong(
                    usize,
                    &node.end_index,
                    end_index,
                    aligned_index + n,
                    .acquire,
                    .monotonic,
                )) {
                    const new_buf = allocated_slice.ptr[0..new_size][@sizeOf(Node)..];
                    return new_buf[aligned_index..][0..n].ptr;
                }
            }
        }
    }
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
