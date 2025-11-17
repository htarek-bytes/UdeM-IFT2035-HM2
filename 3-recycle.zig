// ============================================================================
//
// HIRECHE TARIK - IFT2035 - UNIVERSITÉ DE MONTRÉAL - matricule 202 301 89
// Mohammed Kamal Skhy - IFT2035 - UNIVERSITÉ DE MONTRÉAL - matricule 202 283 77
// ============================================================================
// SOURCES UTILISÉES (PLUS DE DÉTAILS DANS LE RAPPORT):
//
// - Documentation officielle de Zig (std.mem et std.testing):
//   https://ziglang.org/documentation/0.15.2/std/#mem
//   https://ziglang.org/documentation/0.15.2/std/#testing
//
// - Exemples de la librairie standard Zig pour la création d’allocateurs:
//   https://github.com/ziglang/zig/blob/master/lib/std/mem.zig
//
// - Notes de cours IFT2035 sur la gestion de mémoire (allocateurs à pile,
//   allocateurs à étiquette et recyclage de blocs).
//
// - Zig allocators tutorial par ziggit.dev :
//   https://ziggit.dev/t/how-to-write-a-custom-allocator/1209
//
// - Discussion avec ChatGPT pour le débogage de l’alignement
//   inter-architecture (x86/ARM). Le casse-tête des pointeurs non alignés
//   a enfin été dompté grâce à l’usage de `std.mem.bytesAsValue` haha (c'etait vraiment chiant).
//
// ============================================================================

const std = @import("std");

// alright, basically le même principe que pour l’allocateur à étiquette : chaque bloc
// est précédé d’un petit header qui contient la taille et un flag de liberté.
const Header = struct {
    len: usize,
    free: bool,
};

const header_alignment = std.mem.Alignment.of(Header);

const AllocateurRecycle = struct {
    buffer: []u8,
    next: usize,

    fn init(buffer: []u8) AllocateurRecycle {
        return .{ .buffer = buffer, .next = 0 };
    }

    fn allocator(self: *AllocateurRecycle) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address;
        const self: *AllocateurRecycle = @ptrCast(@alignCast(ctx));

        // on peut supposer alignment <= 8 comme indiqué par l’énoncé de Matteo,
        // donc on se contente de garantir un alignement de 8 via Header.
        _ = alignment;

        const base_addr = @intFromPtr(self.buffer.ptr);

        // Etape 1 : on cherche un bloc libre réutilisable
        var offset: usize = 0;
        while (offset < self.next) {
            // on recalcule l’adresse du header en alignant à 8 (alignement de Header)
            const header_addr = std.mem.alignForward(
                usize,
                base_addr + offset,
                header_alignment.toByteUnits(),
            );
            const header_offset = header_addr - base_addr;
            if (header_offset >= self.next) break;

            const header_ptr: *Header = @ptrFromInt(header_addr);

            if (header_ptr.free and header_ptr.len >= len) {
                header_ptr.free = false;
                const data_addr = header_addr + @sizeOf(Header);
                return @ptrFromInt(data_addr);
            }

            // on saute ce bloc : données = juste après le header
            // et puis on avance de len octets
            const data_addr = header_addr + @sizeOf(Header);
            const data_offset = data_addr - base_addr;
            offset = data_offset + header_ptr.len;
        }

        // Etape 2 : on alloue à la fin du buffer
        const current_addr = base_addr + self.next;

        // on aligne le header sur l’alignement de Header (8 en pratique)
        const header_addr = std.mem.alignForward(
            usize,
            current_addr,
            header_alignment.toByteUnits(),
        );
        const data_addr = header_addr + @sizeOf(Header);
        const data_offset = data_addr - base_addr;

        const end_offset = data_offset + len;
        if (end_offset > self.buffer.len)
            return null;

        // alright, ici on écrit le Header sans violer l’alignement.
        const header_ptr: *Header = @ptrFromInt(header_addr);
        header_ptr.* = Header{ .len = len, .free = false };

        self.next = end_offset;
        return @ptrFromInt(data_addr);
    }

    fn getHeader(ptr: [*]u8) *Header {
        const header_addr = @intFromPtr(ptr) - @sizeOf(Header);
        const header_ptr: *Header = @ptrFromInt(header_addr);
        return header_ptr;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = ctx;
        _ = alignment;
        _ = return_address;

        // ici bah pareil : on marque juste le header comme libre.
        const header = getHeader(buf.ptr);
        header.free = true;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "allocations simples" {
    var buffer: [128]u8 = undefined;
    var recycle = AllocateurRecycle.init(&buffer);
    const allocator = recycle.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u8);
    const c = try allocator.create(u8);
    const d = try allocator.create(u8);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 1 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(c);

    const e = try allocator.create(u8);
    try expectEqual(c, e);

    const f = try allocator.create(u8);
    try expect(@intFromPtr(d) + 1 <= @intFromPtr(f));
}

test "allocations à plusieurs octets" {
    var buffer: [128]u8 = undefined;
    var recycle = AllocateurRecycle.init(&buffer);
    const allocator = recycle.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u64);
    const c = try allocator.create(u8);
    const d = try allocator.create(u16);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 8 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(a);
    allocator.destroy(b);
    allocator.destroy(c);
    allocator.destroy(d);

    const e = try allocator.create(u24);
    try expectEqual(@intFromPtr(b), @intFromPtr(e));

    const f = try allocator.create(u16);
    try expectEqual(@intFromPtr(d), @intFromPtr(f));

    const g = try allocator.create(u16);
    try expect(@intFromPtr(d) + 2 <= @intFromPtr(g));
}

test "allocation de tableaux" {
    var buffer: [128]u8 = undefined;
    var recycle = AllocateurRecycle.init(&buffer);
    const allocator = recycle.allocator();

    const a = try allocator.alloc(u8, 1);
    const b = try allocator.alloc(u32, 10);
    const c = try allocator.create(u64);

    try expect(@intFromPtr(&a[0]) + 1 <= @intFromPtr(&b[0]));
    try expectEqual(10, b.len);
    try expect(@intFromPtr(&b[9]) + 4 <= @intFromPtr(c));

    allocator.free(b);

    const d = try allocator.alloc(u64, 4);
    try expectEqual(@intFromPtr(b.ptr), @intFromPtr(d.ptr));
}
