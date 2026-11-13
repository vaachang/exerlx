const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Attribute = struct {
    // const 不能通过这个切片修改它指向的字节内容
    // 一个attribute有key和value，都是字符串
    name: []const u8,
    value: []const u8,
};

pub const Content = union(enum) {
    // <tag> content1 content2 </tag>
    // 每个content要么是纯字符串，要么是注释，要么是</>开头的element
    char_data: []const u8,
    comment: []const u8,
    element: *Element,
};

pub const Element = struct {
    // 每个元素的标签<tag>
    tag: []const u8,
    // &.{}构造一个空切片。
    // .{} 是一个空数组字面量，& 取它的地址，得到指向长度为 0 的数组的指针，
    // 再由上下文自动转换成 []Attribute 切片。长度是 0，所以不需要实际分配内存。
    // 开始标签中的属性列表<tag A=a B=b>
    attributes: []Attribute = &.{},
    // 起止标签中间的内容<tag> content1 content2 </tag>
    // 有个注释好像注错了，*是单元素指针，不是未知个数元素的指针
    children: []Content = &.{},

    pub fn getAttribute(self: Element, attrib_name: []const u8) ?[]const u8 {
        for (self.attributes) |child| {
            // 按照字节对比两个字符串切片内容是否完全相等
            // 遍历自己的属性列表，相同则返回对应的value
            if (mem.eql(u8, child.name, attrib_name)) {
                return child.value;
            }
        }

        // 没有匹配上，返回null
        return null;
    }

    pub fn getCharData(self: Element, child_tag: []const u8) ?[]const u8 {
        const child = self.findChildByTag(child_tag) orelse return null;
        if (child.children.len != 1) {
            return null;
        }
        return switch (child.children[0]) {
            .char_data => |char_data| char_data,
            else => null,
        };
    }

    pub fn iterator(self: Element) ChildIterator {
        return .{
            .items = self.children,
            .i = 0,
        };
    }

    pub fn elements(self: Element) ChildElementIterator {
        return .{
            .inner = self.iterator(),
        };
    }

    pub fn findChildByTag(self: Element, tag: []const u8) ?*Element {
        var it = self.findChildrenByTag(tag);
        return it.next();
    }

    pub fn findChildrenByTag(self: Element, tag: []const u8) FindChildrenByTagIterator {
        return .{
            .inner = self.elements(),
            .tag = tag,
        };
    }

    pub const ChildIterator = struct {
        items: []Content,
        i: usize,

        pub fn next(self: *ChildIterator) ?*Content {
            if (self.i < self.items.len) {
                self.i += 1;
                return &self.items[self.i - 1];
            }
            return null;
        }
    };

    pub const ChildElementIterator = struct {
        inner: ChildIterator,
        pub fn next(self: *ChildElementIterator) ?*Element {
            while (self.inner.next()) |child| {
                if (child.* != .element) {
                    continue;
                }
                return child.*.element;
            }
            return null;
        }
    };

    pub const FindChildrenByTagIterator = struct {
        inner: ChildElementIterator,
        tag: []const u8,

        pub fn next(self: *FindChildrenByTagIterator) ?*Element {
            while (self.inner.next()) |child| {
                if (!mem.eql(u8, child.tag, self.tag)) {
                    continue;
                }
                return child;
            }
            return null;
        }
    };
};
