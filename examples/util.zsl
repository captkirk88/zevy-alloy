const zsl = @import("../zsl.zig");

/// Maximum N for which factorial fits in u32. (12! = 479001600)
pub const max_factorial_n: u32 = 12;

/// Compute n! iteratively. Returns 1 for n == 0 and clamps to 1 for n > max_factorial_n.
pub fn factorial(n: u32) u32 {
    if (n >= 13) return 1;
    var acc: u32 = 1;
    var i: u32 = 2;
    while (i <= n) {
        acc = acc * i;
        i = i + 1;
    }
    return acc;
}
