// ============================================================================
//
// HIRECHE TARIK - IFT2035 - UNIVERSITE DE MONTREAL - matricule 202 301 89
// Mohammed Kamal Skhy - IFT2035 - UNIVERSITE DE MONTREAL - matricule 202 283 77
// ============================================================================
// SOURCES UTILISEES
//
// - Documentation officielle de Zig (std.mem et std.testing):
//   https://ziglang.org/documentation/0.15.2/std/#mem
//   https://ziglang.org/documentation/0.15.2/std/#testing
//
// - Exemples de la librairie standard Zig pour l'utilisation des allocateurs:
//   https://github.com/ziglang/zig/blob/master/lib/std/mem.zig
//
// - Notes de cours IFT2035 sur la gestion de memoire (allocateurs a pile)
//   et sur les structures d'allocateurs etiquetes
//
// - Zig allocators tutorial par ziggit.dev :
//   https://ziggit.dev/t/how-to-write-a-custom-allocator/1209
//
// - CHATGPT pour clarifications sur l'implementation de l'allocateur a pile,
//   verification des cas limites, et explications sur l'alignement memoire.
//
// ============================================================================

const std = @import("std");

const AllocateurPile = struct {
    buffer: []u8, // ici c’est la zone mémoire brute dans laquelle on va allouer nos trucs
    next: usize, // ca, c’est juste un index qui nous dit “ok, la prochaine case libre est ici”

    /// alright guys, ici on initialise notre allocateur avec un buffer vide.
    /// en gros, on prend un bloc mémoire existant et on se le reserve.
    fn init(buffer: []u8) AllocateurPile {
        return .{
            .buffer = buffer,
            .next = 0, // on commence à zero, logique : rien n’est encore alloué
        };
    }

    /// ici on crée un vrai objet “Allocator” compatible avec les fonctions standard de Zig.
    /// ça veut juste dire que notre truc respecte l’interface officielle des allocateurs.
    fn allocator(self: *AllocateurPile) std.mem.Allocator {
        return .{
            .ptr = self, // on garde une référence vers notre instance
            .vtable = &.{
                .alloc = alloc, // notre fonction principale d’allocation
                .free = std.mem.Allocator.noFree, // pas de libération individuelle (pile = tout ou rien)
                .resize = std.mem.Allocator.noResize, // on ne redimensionne rien ici
                .remap = std.mem.Allocator.noRemap, // ni de remapping
            },
        };
    }

    /// voilà la partie intéressante : la fonction qui essaie d’allouer un bloc mémoire.
    /// le but c’est simple : on veut réserver “len” octets dans notre buffer,
    /// en respectant l’alignement demandé (genre pour les u64, il faut être sur un multiple de 8).
    fn alloc(
        ctx: *anyopaque, // pointeur “generique” passé par le système
        len: usize, // taille à allouer en octets
        alignment: std.mem.Alignment, // alignement demandé (1, 2, 4, 8, etc.)
        return_address: usize, // on s’en fout ici, juste pour le protocole
    ) ?[*]u8 {
        _ = return_address;

        // on récupère notre allocateur reel à partir du pointeur brut
        const self: *AllocateurPile = @ptrCast(@alignCast(ctx));

        // ici on prend note de la position actuelle du “curseur” d’allocation
        const current = self.next;

        // maintenant on veut s’assurer que l’adresse où on va allouer est bien alignée.
        // Dans la version précédente, on alignait juste l’index relatif (current),
        // mais si le buffer lui-même (self.buffer.ptr) ne commence pas sur un multiple
        // de 8, 4, etc., alors le calcul n’est plus valide. Résultat: crash sur certaines
        // plateformes comme macOS/ARM. Ici, on aligne donc l’adresse absolue en mémoire.
        const base_ptr = @intFromPtr(self.buffer.ptr); // adresse réelle du début du buffer
        const absolute_current = base_ptr + current; // position absolue actuelle
        const aligned_addr = std.mem.alignForward(usize, absolute_current, alignment.toByteUnits());
        const start = aligned_addr - base_ptr; // on revient à un offset relatif dans le buffer

        // là on check : est-ce qu’on dépasse la taille du buffer ?
        // si oui... et bah pas assez de place donc on retourne null
        if (start + len > self.buffer.len) {
            return null;
        }

        // si on arrive ici, c’est que tout va bien.
        // on avance notre curseur interne pour la prochaine allocation.
        self.next = start + len;

        // enfin, on retourne un pointeur vers le début du bloc qu’on vient d’allouer.
        // à noter : on ne retourne pas une slice, mais bien un pointeur brut.
        return @as([*]u8, @ptrFromInt(aligned_addr));
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "allocations simples" {
    var buffer: [4]u8 = undefined;
    var pile = AllocateurPile.init(&buffer);
    const allocator = pile.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u8);
    const c = try allocator.create(u8);
    const d = try allocator.create(u8);
    const e = allocator.create(u8);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 1 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));
    try expectEqual(error.OutOfMemory, e);

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);
}

test "allocations à plusieurs octets" {
    var buffer: [32]u8 = undefined;
    var pile = AllocateurPile.init(&buffer);
    const allocator = pile.allocator();

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
}

test "allocation de tableaux" {
    var buffer: [128]u8 = undefined;
    var pile = AllocateurPile.init(&buffer);
    const allocator = pile.allocator();

    const a = try allocator.alloc(u8, 1);
    const b = try allocator.alloc(u32, 10);
    const c = try allocator.create(u64);

    try expect(@intFromPtr(&a[0]) + 1 <= @intFromPtr(&b[0]));
    try expectEqual(10, b.len);
    try expect(@intFromPtr(&b[9]) + 4 <= @intFromPtr(c));
}


// ===============================================================
// == TESTS ALLOCATEUR À PILE – EXTENDED SUITE ===================
// ===============================================================
test "remplissage exact du buffer" {
    var buffer: [24]u8 = undefined;
    var pile = AllocateurPile.init(&buffer);
    const allocator = pile.allocator();

    const a = try allocator.alloc(u8, 8);   // 8 octets
    const b = try allocator.alloc(u16, 4);  // 8 octets
    const c = try allocator.alloc(u32, 2);  // 8 octets
    const d = allocator.alloc(u8, 1);       // pile pleine ici → doit échouer

    _ = a; _ = b; _ = c;

    try expectEqual(error.OutOfMemory, d);
}


test "stress test -> plusieurs petites allocations" {
    var buffer: [256]u8 = undefined;
    var pile = AllocateurPile.init(&buffer);
    const allocator = pile.allocator();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const ptr = allocator.create(u8) catch |err| {
            try expectEqual(error.OutOfMemory, err);
            break;
        };
        ptr.* = @as(u8, @intCast(i)); // ✅ correction ici
    }

    var count: usize = 0;
    while (count < 64 and count < pile.next) : (count += 1) {
        try expect(buffer[count] == @as(u8, @intCast(count)));
    }
}
