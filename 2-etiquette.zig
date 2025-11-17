// ============================================================================
//
// HIRECHE TARIK - IFT2035 - UNIVERSITE DE MONTREAL - matricule 202 301 89
// Mohammed Kamal Skhy - IFT2035 - UNIVERSITE DE MONTREAL - matricule 202 283 77
// ============================================================================
// SOURCES UTILISEES (PLUS DE DETAILS DANS LE RAPPORT):
//
// - Documentation officielle de Zig (std.mem et std.testing):
//   https://ziglang.org/documentation/0.15.2/std/#mem
//   https://ziglang.org/documentation/0.15.2/std/#testing
//
// - Exemples de la librairie standard Zig pour l'utilisation des allocateurs:
//   https://github.com/ziglang/zig/blob/master/lib/std/mem.zig
//
// - Notes de cours IFT2035 sur la gestion de mémoire (allocateurs à pile)
//   et sur les structures d'allocateurs étiquetés
//
// - Zig allocators tutorial par ziggit.dev :
//   https://ziggit.dev/t/how-to-write-a-custom-allocator/1209
//
// - Discussion avec ChatGPT (modèle GPT-5) pour clarifications sur :
//   l’alignement mémoire absolu, la compatibilité inter-architecture (x86, ARM),
//   et la bonne gestion du pointeur opaque dans les allocateurs personnalisés.
//
// ============================================================================


const std = @import("std");

// okkk alors ici on définit la petite "étiquette" (le header) qu'on va coller
// juste avant chaque allocation. Ça sert à garder deux infos importantes :
// - combien d’octets on a pris (le len)
// - est-ce que ce bloc est libre ou occupé (free)
const Header = struct {
    len: usize,
    free: bool,
};

// ici on récupère l’alignement du type Header, histoire de placer les choses
// proprement en mémoire (utile surtout sur architectures strictes comme ARM)
const header_alignment = std.mem.Alignment.of(Header);

// voilà notre allocateur version "étiquette" : basically la même idée que la pile,
// sauf que cette fois on garde un petit header avant chaque bloc alloué.
// Ça nous permet de garder une trace de la taille et de l’état du bloc.
const AllocateurEtiquette = struct {
    buffer: []u8,
    next: usize,

    /// ici on initialise notre allocateur avec un buffer vide.
    /// en gros, on se réserve une zone mémoire à utiliser comme "mini tas".
    fn init(buffer: []u8) AllocateurEtiquette {
        return .{
            .buffer = buffer,
            .next = 0,
        };
    }

    /// ici on crée un vrai objet Allocator compatible avec les fonctions
    /// standard de Zig (allocator.create, alloc, destroy, etc.)
    /// → en gros, on branche notre allocateur custom dans l’interface officielle.
    fn allocator(self: *AllocateurEtiquette) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = deallocate, // renommé pour éviter le conflit avec mot-clé Zig
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }

    /// la partie principale : essayer d’allouer `len` octets avec un certain alignement.
    /// ici, on stocke aussi un header juste avant le bloc.
    ///
    /// NOTE IMPORTANTE:
    /// Dans notre première version, on calculait les offsets à partir de `self.next`
    /// sans tenir compte de l’adresse réelle du buffer. Sur macOS/ARM, ça plante
    /// car le buffer de pile `[N]u8` peut commencer à une adresse non alignée.
    ///
    /// Ici, on aligne *l’adresse absolue* en mémoire, ce qui rend le code portable
    /// sur toutes les architectures et évite le "panic: incorrect alignment".
    fn alloc(
        ctx: *anyopaque, // pointeur générique passé par le système
        len: usize, // taille à allouer en octets
        alignment: std.mem.Alignment, // alignement demandé (1, 2, 4, 8, etc.)
        return_address: usize, // inutile ici mais requis par la vtable
    ) ?[*]u8 {
        _ = return_address;

        // on récupère notre vrai allocateur à partir du pointeur brut
        const self: *AllocateurEtiquette = @ptrCast(@alignCast(ctx));

        // on travaille avec des adresses absolues pour que l’alignement
        // tienne compte de l’adresse réelle du buffer (important sur macOS/ARM)
        const base_addr = @intFromPtr(self.buffer.ptr);
        const current_addr = base_addr + self.next;

        // on aligne d’abord l’adresse du header selon l’alignement du type Header
        const header_addr = std.mem.alignForward(usize, current_addr, header_alignment.toByteUnits());

        // puis l’adresse du bloc de données selon l’alignement demandé par l’utilisateur
        const data_addr = std.mem.alignForward(usize, header_addr + @sizeOf(Header), alignment.toByteUnits());

        // on calcule les offsets relatifs dans le buffer (par rapport au début)
        const data_start = data_addr - base_addr;

        // vérif : est-ce qu’on a encore de la place dans le buffer ?
        const total_size = (data_start + len) - self.next;
        if (self.next + total_size > self.buffer.len) {
            return null;
        }

        // on écrit notre header juste avant le bloc alloué
        const header_ptr: *Header = @ptrFromInt(header_addr);
        header_ptr.* = Header{
            .len = len,
            .free = false,
        };

        // on avance le curseur pour la prochaine allocation
        self.next = data_start + len;

        // on renvoie le pointeur vers le bloc de données
        return @ptrFromInt(data_addr);
    }

    /// ici on retrouve le header d’un bloc à partir de son pointeur
    /// (on recule en mémoire pour pointer vers le header).
    /// On reste dans le domaine des pointeurs typés → pas de cast hasardeux via int.
    fn getHeader(ptr: [*]u8) *Header {
        const raw_ptr = ptr - @sizeOf(Header);
        return @ptrCast(@alignCast(raw_ptr));
    }

    /// et ici, bah on "libère" un bloc (en vrai on fait juste marquer son header comme libre).
    /// Pas de gestion de réutilisation ici — ça viendra avec un recycleur.
    fn deallocate(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = ctx;
        _ = alignment;
        _ = return_address;

        // on va chercher le header lié au bloc
        const header = getHeader(buf.ptr);

        // on le marque comme libre
        header.free = true;
    }
};


const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "allocations simples" {
    var buffer: [128]u8 = undefined;
    var etiquette = AllocateurEtiquette.init(&buffer);
    const allocator = etiquette.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u8);
    const c = try allocator.create(u8);
    const d = try allocator.create(u8);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 1 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(a)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(a)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(b)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(c)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(d)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(d)).len);

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(c);

    try expectEqual(true, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(c)).len);
}

test "allocations à plusieurs octets" {
    var buffer: [128]u8 = undefined;
    var etiquette = AllocateurEtiquette.init(&buffer);
    const allocator = etiquette.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u64);
    const c = try allocator.create(u8);
    const d = try allocator.create(u16);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 8 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(a)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(a)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(8, AllocateurEtiquette.getHeader(@ptrCast(b)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(c)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(d)).free);
    try expectEqual(2, AllocateurEtiquette.getHeader(@ptrCast(d)).len);

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(b);

    try expectEqual(true, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(8, AllocateurEtiquette.getHeader(@ptrCast(b)).len);
}

test "allocation de tableaux" {
    var buffer: [128]u8 = undefined;
    var etiquette = AllocateurEtiquette.init(&buffer);
    const allocator = etiquette.allocator();

    const a = try allocator.alloc(u8, 1);
    const b = try allocator.alloc(u32, 10);
    const c = try allocator.create(u64);

    try expect(@intFromPtr(&a[0]) + 1 <= @intFromPtr(&b[0]));
    try expectEqual(10, b.len);
    try expect(@intFromPtr(&b[9]) + 4 <= @intFromPtr(c));

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(a)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(a)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(40, AllocateurEtiquette.getHeader(@ptrCast(b)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(8, AllocateurEtiquette.getHeader(@ptrCast(c)).len);

    allocator.free(b);

    try expectEqual(true, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(40, AllocateurEtiquette.getHeader(@ptrCast(b)).len);
}
